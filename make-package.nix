{ lib }:

let
  inherit (lib) attrByPath getOutput flatten optionalString optional optionals subtractLists splitString;

  getAllOutputs = f: flatten (map (x: map (name: getOutput name x) x.outputs) f);

  makePackage' = {
    # meta
    pname, version

    # outputs
  , outputs ? ["out"], setOutputFlags ? true
  , outputDev ? null, outputBin ? null, outputInclude ? null
  , outputLib ? null, outputDoc ? null, outputDevdoc ? null
  , outputMan ? null, outputDevman ? null, outputInfo ? null

    # system
  , packages, system ? stdenv.buildPlatform.system, stdenv ? packages.stdenv

    # unpack phase
  , src, dontMakeSourcesWritable ? false, sourceRoot ? null
  , preUnpack ? "", postUnpack ? ""

    # patch phase
  , patches ? [], prePatch ? "", postPatch ? ""

    # configure phase
  , dontConfigure ? false, configureFlags ? [], configureScript ? null
  , configurePlatforms ? [ "build" "host" "target" ]
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

    # error checking
    disallowEnvironment = name: if (environment ? name) then "makePackage argument 'environment' cannot contain '${name}'" else null;
    requireType = name: type: if (builtins.hasAttr name attrs && builtins.typeOf (attrs.${name}) != type) then "makePackage argument '${name}' should be of type '${type}' but got type '${builtins.typeOf attrs.${name}}'" else null;
    headOrNull = l: if builtins.length l == 0 then null else builtins.head l;
    requireListType = name: type: if builtins.hasAttr name attrs then headOrNull (builtins.filter (v: !(isNull v)) (map (v:
      if (builtins.typeOf v != type)
        then "makePackage argument '${name}' should be a list of type '${type}' but found a list element of type '${builtins.typeOf attrs.${name}}'"
        else null
    ) attrs.${name})) else null;
    requireListOf = name: list: if builtins.hasAttr name attrs then (
      headOrNull (builtins.filter (v: !(isNull v)) (map (v:
        if builtins.elem v list then null
        else "makePackage argument '${name}' should be a list of [${toString list}], but found '${v}'")
        attrs.${name}))
    ) else null;
    errMessages = builtins.filter (v: !(isNull v)) [
      (disallowEnvironment "buildCommand")
      (disallowEnvironment "unpackPhase")
      (disallowEnvironment "patchPhase")
      (disallowEnvironment "configurePhase")
      (disallowEnvironment "buildPhase")
      (disallowEnvironment "checkPhase")
      (disallowEnvironment "fixupPhase")
      # TODO: error any time something in environment is overriden
      (requireType "pname" "string")
      (requireType "version" "string")
      (requireType "setOutputFlags" "bool")
      (requireType "packages" "set")
      (requireType "stdenv" "set")
      (requireType "dontMakeSourcesWritable" "bool")
      (requireType "preUnpack" "string")
      (requireType "postUnpack" "string")
      (requireType "patches" "list")
      # (requireListType "patches" "path")
      (requireType "prePatch" "string")
      (requireType "postPatch" "string")
      (requireType "dontConfigure" "bool")
      (requireType "configureFlags" "list")
      (requireListType "configureFlags" "string")
      (requireType "preConfigure" "string")
      (requireType "postConfigure" "string")
      (requireType "dontDisableStatic" "bool")
      (requireType "dontAddDisableDepTrack" "bool")
      (requireType "dontAddPrefix" "bool")
      (requireType "dontFixLibtool" "bool")
      (requireType "cmakeFlags" "list")
      (requireListType "cmakeFlags" "string")
      (requireType "mesonFlags" "list")
      (requireListType "mesonFlags" "string")
      (requireType "dontBuild" "bool")
      (requireType "enableParallelBuilding" "bool")
      (requireType "makeFlags" "list")
      (requireType "preBuild" "string")
      (requireType "postBuild" "string")
      (requireType "hardeningEnable" "list")
      (requireListOf "hardeningEnable" [ "all" "fortify" "stackprotector" "pie" "pic" "strictoverflow" "format" "relro" "bindnow" ])
      (requireType "hardeningDisable" "list")
      (requireListOf "hardeningDisable" [ "all" "fortify" "stackprotector" "pie" "pic" "strictoverflow" "format" "relro" "bindnow" ])
      (requireType "doCheck" "bool")
      (requireType "enableParallelChecking" "bool")
      (requireType "preCheck" "string")
      (requireType "postCheck" "string")
      (requireType "dontInstall" "bool")
      (requireType "installFlags" "list")
      (requireListType "installFlags" "string")
      (requireType "preInstall" "string")
      (requireType "postInstall" "string")
      (requireType "dontFixup" "bool")
      (requireType "setupHooks" "list")
      (requireType "separateDebugInfo" "bool")
      (requireType "preFixup" "string")
      (requireType "postFixup" "string")
      (requireType "buildInputs" "list")
      (requireType "propagatedBuildInputs" "list")
      (requireType "nativeBuildInputs" "list")
      (requireType "checkInputs" "list")
      (requireType "propagatedNativeBuildInputs" "list")
      (requireType "depsBuildBuild" "list")
      (requireType "depsBuildBuildPropagated" "list")
      (requireType "depsBuildHost" "list")
      (requireType "depsBuildHostPropagated" "list")
      (requireType "depsBuildTarget" "list")
      (requireType "depsBuildTargetPropagated" "list")
      (requireType "depsHostHost" "list")
      (requireType "depsHostHostPropagated" "list")
      (requireType "depsHostTarget" "list")
      (requireType "depsHostTargetPropagated" "list")
      (requireType "depsTargetTarget" "list")
      (requireType "depsTargetTargetPropagated" "list")
      (requireType "debug" "int")
      (requireType "showBuildStats" "bool")
      (requireType "environment" "set")
      (requireType "configurePlatforms" "list")
      (requireListOf "configurePlatforms" ["build" "host" "target"])
    ];

  in if errMessages == [] then ((derivation (environment // {
    inherit system;
    name = "${pname}-${version}";

    outputs = outputs ++ optional separateDebugInfo "debug";
    inherit setOutputFlags;
    inherit outputDev outputBin outputInclude outputLib;
    inherit outputDoc outputDevdoc outputMan outputDevman outputInfo;

    __ignoreNulls = true;

    # requires https://github.com/NixOS/nixpkgs/pull/85042
    # __structuredAttrs = true;

    # generic builder
    inherit stdenv;
    builder = stdenv.shell;
    args = [ "-e" (builtins.toFile "builder.sh" (''
      if [ -e .attrs.sh ]; then source .attrs.sh; fi
      source $stdenv/setup
      genericBuild
    '' + optionalString separateDebugInfo ''
      mkdir -p $debug # hack to ensure debug always exists
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

    # TODO: should also disallow “debug” outputs anywhere
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
    configureFlags = []
      ++ optional (builtins.elem "build"  configurePlatforms) "--build=${stdenv.buildPlatform.config}"
      ++ optional (builtins.elem "host"   configurePlatforms) "--host=${stdenv.hostPlatform.config}"
      ++ optional (builtins.elem "target" configurePlatforms) "--target=${stdenv.targetPlatform.config}"
      ++ configureFlags;

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
        else stdenv.hostPlatform.parsed.cpu.family + builtins.toString stdenv.hostPlatform.parsed.cpu.bits}'
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
  }) else throw (builtins.head errMessages);
in packages: packageFun: (makePackage' ((packageFun packages) // { inherit packages; })) // {
     inherit packageFun;

     # TODO: implement override
   }
