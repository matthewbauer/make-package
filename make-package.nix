{ lib }:

let
  inherit (lib) attrByPath getOutput flatten optionalString optional optionals subtractLists splitString;

  getAllOutputs = f: flatten (map (x: map (name: getOutput name x) x.outputs) f);

  makePackage' = {
    pname, version, outputs ? ["out"]

    # system
  , packages, system ? stdenv.buildPlatform.system, stdenv ? packages.stdenv

    # unpack phase
  , src, dontMakeSourcesWritable ? false, sourceRoot ? null
  , preUnpack ? "", postUnpack ? ""

    # patch phase
  , patches ? [], prePatch ? "", postPatch ? ""

    # configure phase
  , dontConfigure ? false, configureFlags ? [], configureScript ? null
  , preConfigure ? "", postConfigure ? ""
  , dontDisableStatic ? false, dontAddDisableDepTrack ? false, dontAddPrefix ? false, dontFixLibtool ? false
  , cmakeFlags ? []
  , mesonFlags ? []

    # build phase
  , dontBuild ? false, enableParallelBuilding ? true, makeFlags ? [], makefile ? null
  , preBuild ? "", postBuild ? ""
  , hardeningEnable ? [], hardeningDisable ? []

    # check phase
  , doCheck ? true, enableParallelChecking ? true, checkTarget ? null
  , preCheck ? "", postCheck ? ""

    # install phase
  , dontInstall ? false, installFlags ? []
  , preInstall ? "", postInstall ? ""

    # fixup phase
  , dontFixup ? false, setupHooks ? []
  , separateDebugInfo ? !stdenv.hostPlatform.isDarwin # broken on macOS
  , preFixup ? "", postFixup ? ""

    # inputs
  , buildInputs ? [], propagatedBuildInputs ? []
  , nativeBuildInputs ? []
  , propagatedNativeBuildInputs ? []
  , checkInputs ? []

  , depsBuildBuild ? [], depsBuildBuildPropagated ? []
  , depsBuildHost ? [], depsBuildHostPropagated ? []
  , depsBuildTarget ? [], depsBuildTargetPropagated ? []
  , depsHostHost ? [], depsHostHostPropagated ? []
  , depsHostTarget ? [], depsHostTargetPropagated ? []
  , depsTargetTarget ? [], depsTargetTargetPropagated ? []

  , allowedRequisites ? null, allowedReferences ? null, disallowedRequisites ? [], disallowedReferences ? []
  , exportReferencesGraph ? []

    # debug
  , debug ? 0, showBuildStats ? false

    # environment stuff, should be used sparingly
  , environment ? {}, impureEnvVars ? []

    # miscellaneous
  , allowSubstitutes ? true, preferLocalBuild ? false, passAsFile ? []
  , outputHash ? null, outputHashAlgo ? null, outputHashMode ? null
  } @ attrs: let

    # TODO: this should run closePropagation to get propagated build inputs in drv
    splicePackage = hostOffset: targetOffset: isPropagated: identifier:
      if builtins.isString identifier
      then (let
        packages' = if (hostOffset == -1 && targetOffset == -1) then packages.pkgsBuildBuild
          else if (hostOffset == -1 && targetOffset == 0) then packages.pkgsBuildHost
          else if (hostOffset == -1 && targetOffset == 1) then packages.pkgsBuildTarget
          else if (hostOffset == 0 && targetOffset == 0) then packages.pkgsHostHost
          else if (hostOffset == 0 && targetOffset == 1) then packages.pkgsHostTarget
          else if (hostOffset == 1 && targetOffset == 1) then packages.pkgsTargetTarget
          else throw "unknown offset combination: (${hostOffset}, ${targetOffset})";
        in   if (attrByPath ((splitString "." identifier) ++ ["packageFun"]) null packages != null) then makePackage' ((attrByPath ((splitString "." identifier) ++ ["packageFun"]) null packages) packages' // { packages = packages'; })
        else if (attrByPath (splitString "." identifier) null packages' != null) then attrByPath (splitString "." identifier) null packages'
        else throw "Could not find '${identifier}'. Dependencies of makePackage should also be created with makePackage.")

      # TODO: if the package has the right offsets, we could allow them to be used here
      else throw "package must be a string identifier";

    depsBuildBuild' = flatten (map (splicePackage (-1) (-1) false) depsBuildBuild);
    depsBuildBuildPropagated' = flatten (map (splicePackage (-1) (-1) true) depsBuildBuildPropagated);
    depsBuildHost' = flatten (map (splicePackage (-1) 0 false) (
         depsBuildHost ++ buildInputs ++ nativeBuildInputs ++ checkInputs
      ++ optional separateDebugInfo "separateDebugInfo"
    ));
    depsBuildHostPropagated' = flatten (map (splicePackage (-1) 0 true) (
      depsBuildHostPropagated ++ propagatedNativeBuildInputs ++ propagatedBuildInputs
    ));
    depsBuildTarget' = map (splicePackage (-1) 1 false) depsBuildTarget;
    depsBuildTargetPropagated' = map (splicePackage (-1) 1 true) depsBuildTargetPropagated;
    depsHostHost' = map (splicePackage 0 0 false) depsHostHost;
    depsHostHostPropagated' = map (splicePackage 0 0 true) depsHostHostPropagated;
    depsHostTarget' = map (splicePackage 0 1 false) (depsHostTarget ++ buildInputs);
    depsHostTargetPropagated' = map (splicePackage 0 1 true) (
      depsHostTargetPropagated ++ propagatedBuildInputs
    );
    depsTargetTarget' = map (splicePackage 1 1 false) depsTargetTarget;
    depsTargetTargetPropagated' = map (splicePackage 1 1 true) depsTargetTargetPropagated;

  in (derivation (builtins.removeAttrs environment ["buildCommand" "unpackPhase" "patchPhase" "configurePhase" "buildPhase" "checkPhase" "fixupPhase"] // {
    inherit system;
    name = "${pname}-${version}";
    outputs = outputs ++ optional separateDebugInfo "debug";
    __ignoreNulls = true;

    # requires https://github.com/NixOS/nixpkgs/pull/85042
    # __structuredAttrs = true;

    # generic builder
    inherit stdenv;
    builder = stdenv.shell;
    args = [ "-e" (builtins.toFile "builder.sh" (''
      runPhase() {
        local phase="$1"
        eval "''${!phase:-$phase}"
      }
      if [ -e .attrs.sh ]; then source .attrs.sh; fi
      source $stdenv/setup
      genericBuild
    '' + optionalString separateDebugInfo ''
      mkdir $debug # hack to ensure debug always exists
    '')) ];

    # inputs
    strictDeps = true;
    depsBuildBuild = map (getOutput "dev") depsBuildBuild';
    depsBuildBuildPropagated = map (getOutput "dev") depsBuildBuildPropagated';
    nativeBuildInputs = map (getOutput "dev") depsBuildHost';
    propagatedNativeBuildInputs = map (getOutput "dev") depsBuildHostPropagated';
    depsBuildTarget = map (getOutput "dev") depsBuildTarget';
    depsBuildTargetPropagated = map (getOutput "dev") depsBuildTargetPropagated';
    depsHostHost = map (getOutput "dev") depsHostHost';
    depsHostHostPropagated = map (getOutput "dev") depsHostHostPropagated';
    buildInputs = map (getOutput "dev") depsHostTarget';
    propagatedBuildInputs = map (getOutput "dev") depsHostTargetPropagated';
    depsTargetTarget = map (getOutput "dev") depsTargetTarget';
    depsTargetTargetPropagated = map (getOutput "dev") depsTargetTargetPropagated';
    disallowedReferences = disallowedReferences ++ subtractLists
      (getAllOutputs (depsBuildBuildPropagated' ++ depsBuildHostPropagated' ++ depsBuildTargetPropagated' ++ depsHostHost' ++ depsHostHostPropagated' ++ depsHostTarget' ++ depsHostTargetPropagated' ++ depsTargetTarget' ++ depsTargetTargetPropagated'))
      (getAllOutputs (depsBuildBuild' ++ depsBuildHost' ++ depsBuildTarget'));
    inherit allowedRequisites allowedReferences disallowedRequisites exportReferencesGraph;

    # unpack
    dontUnpack = false;
    inherit src preUnpack postUnpack dontMakeSourcesWritable sourceRoot;

    # patch
    dontPatch = false;
    inherit patches prePatch postPatch;

    # configure
    inherit dontConfigure configureScript preConfigure postConfigure;
    configureFlags = [
      "--build=${stdenv.buildPlatform.config}"
      "--host=${stdenv.hostPlatform.config}"
      "--target=${stdenv.targetPlatform.config}"
    ] ++ configureFlags;

    cmakeFlags = [
      "-DCMAKE_SYSTEM_NAME=${stdenv.hostPlatform.uname.system or "Generic"}"
      "-DCMAKE_SYSTEM_PROCESSOR=${stdenv.hostPlatform.uname.processor or ""}"
      "-DCMAKE_SYSTEM_VERSION=${if (stdenv.hostPlatform.uname.release or null != null)
                                then stdenv.hostPlatform.uname.release else ""}"
      "-DCMAKE_HOST_SYSTEM_NAME=${stdenv.buildPlatform.uname.system or "Generic"}"
      "-DCMAKE_HOST_SYSTEM_PROCESSOR=${stdenv.buildPlatform.uname.processor or ""}"
      "-DCMAKE_HOST_SYSTEM_VERSION=${if (stdenv.buildPlatform.uname.release or null != null)
                                     then stdenv.buildPlatform.uname.release else ""}"
    ] ++ cmakeFlags;

    mesonFlags = [ "--cross-file=${builtins.toFile "cross-file.conf" ''
      [properties]
      needs_exe_wrapper = true

      [host_machine]
      system = '${stdenv.hostPlatform.parsed.kernel.name}'
      cpu_family = '${# See https://mesonbuild.com/Reference-tables.html#cpu-families
        if stdenv.hostPlatform.isAarch32 then "arm"
        else if stdenv.hostPlatform.isAarch64 then "aarch64"
        else if stdenv.hostPlatform.isx86_32  then "x86"
        else if stdenv.hostPlatform.isx86_64  then "x86_64"
        else stdenv.hostPlatform.parsed.cpu.family + builtins.toString stdenv.hostPlatform.parsed.cpu.bits}
      cpu = '${stdenv.hostPlatform.parsed.cpu.name}'
      endian = '${if stdenv.hostPlatform.isLittleEndian then "little" else "big"}'
    ''}" ] ++ mesonFlags;

    # build
    inherit dontBuild makeFlags enableParallelBuilding makefile preBuild postBuild;
    NIX_HARDENING_ENABLE = if builtins.elem "all" hardeningDisable then []
      else subtractLists hardeningDisable (
        hardeningEnable ++ [ "fortify" "stackprotector" "pic" "strictoverflow" "format" "relro" "bindnow" ]
      );

    # check
    inherit doCheck enableParallelChecking checkTarget preCheck postCheck;

    # install
    inherit dontInstall installFlags preInstall postInstall;

    # fixup
    inherit dontFixup preFixup postFixup setupHooks;

    # installCheck and dist phases should not be run in a package
    # use another derivation instead
    doInstallCheck = false;
    doDist = false;

    # debugging
    NIX_DEBUG = debug;
    inherit showBuildStats;

    # miscellaneous
    # most of these probably shouldn’t actually be in the drv
    inherit allowSubstitutes preferLocalBuild passAsFile;
    inherit outputHash outputHashAlgo outputHashMode;
    inherit impureEnvVars;
  })) // {
    meta.outputsToInstall = outputs;
    outputSystem = packages.stdenv.hostPlatform.system;
    outputUnspecified = true;
    overrideAttrs = f: makePackage' (attrs // (f attrs));
  };
in packages: packageFun: (makePackage' ((packageFun packages) // { inherit packages; })) // {
     inherit packageFun;

     # TODO: implement override
   }
