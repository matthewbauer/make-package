{
  description = "Tools to compose packages from Nixpkgs, combining callPackage and stdenv.mkDerivation";

  inputs.nixpkgs.url = "nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs.lib) attrByPath genAttrs getOutput flatten optionalString optional optionals subtractLists splitString;
    flattenAttrs = f: builtins.listToAttrs (flatten (
      map (n:
        map (n': { name = "${n}-${n'}"; value = f.${n}.${n'}; }) (builtins.attrNames f.${n})
      ) (builtins.attrNames f)
    ));
    getAllOutputs = f: flatten (map (x: map (name: getOutput name x) x.outputs) f);
    allSystems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" ];
  in {
    makePackage = pkgs: f: (self.makePackage' ((f pkgs) // { inherit pkgs; })) // {
      pkgFun = f;

      # TODO: implement override
    };

    makePackage' = {
      pname, version, outputs ? ["out"]

      # system
    , pkgs, system ? stdenv.buildPlatform.system, stdenv ? pkgs.stdenv

      # unpack phase
    , src, dontMakeSourcesWritable ? false, sourceRoot ? null
    , unpackPhase ? null, preUnpack ? "", postUnpack ? ""

      # patch phase
    , patches ? [], prePatch ? "", postPatch ? ""

      # configure phase
    , dontConfigure ? false, configureFlags ? [], configureScript ? null
    , configurePhase ? "", preConfigure ? "", postConfigure ? ""
    , dontDisableStatic ? false, dontAddDisableDepTrack ? false, dontAddPrefix ? false, dontFixLibtool ? false
    , cmakeFlags ? []
    , mesonFlags ? []

      # build phase
    , dontBuild ? false, enableParallelBuilding ? true, makeFlags ? [], makefile ? null
    , buildPhase ? null, preBuild ? "", postBuild ? ""
    , hardeningEnable ? [], hardeningDisable ? []

      # check phase
    , doCheck ? true, enableParallelChecking ? true, checkTarget ? null
    , checkPhase ? null, preCheck ? "", postCheck ? ""

      # install phase
    , dontInstall ? false, installFlags ? [], installPhase ? null
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
      splicePackage = hostOffset: targetOffset: isPropagated: pkg:
        if builtins.isString pkg
        then (let
          pkgs' = if (hostOffset == -1 && targetOffset == -1) then pkgs.pkgsBuildBuild
            else if (hostOffset == -1 && targetOffset == 0) then pkgs.pkgsBuildHost
            else if (hostOffset == -1 && targetOffset == 1) then pkgs.pkgsBuildTarget
            else if (hostOffset == 0 && targetOffset == 0) then pkgs.pkgsHostHost
            else if (hostOffset == 0 && targetOffset == 1) then pkgs.pkgsHostTarget
            else if (hostOffset == 1 && targetOffset == 1) then pkgs.pkgsTargetTarget
            else throw "unknown offset combination: (${hostOffset}, ${targetOffset})";
          in   if (attrByPath ((splitString "." pkg) ++ ["pkgFun"]) null pkgs != null) then self.makePackage' ((attrByPath ((splitString "." pkg) ++ ["pkgFun"]) null pkgs) pkgs' // { pkgs = pkgs'; })
          else if (attrByPath (splitString "." pkg) null pkgs != null) then attrByPath (splitString "." pkg) null pkgs
          else throw "could not find '${pkg}'")
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

    in (derivation (builtins.removeAttrs environment ["patchPhase" "fixupPhase"] // {
      inherit system;
      name = "${stdenv.hostPlatform.system}-${pname}-${version}";
      outputs = outputs ++ optional separateDebugInfo "debug";
      __ignoreNulls = true;

      # requires https://github.com/NixOS/nixpkgs/pull/85042
      # __structuredAttrs = true;

      # generic builder
      inherit stdenv;
      builder = stdenv.shell;
      args = [ "-e" (builtins.toFile "builder.sh" (''
        [ -e .attrs.sh ] && source .attrs.sh
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
      inherit dontBuild makeFlags enableParallelBuilding makefile buildPhase preBuild postBuild;
      NIX_HARDENING_ENABLE = if builtins.elem "all" hardeningDisable then []
        else subtractLists hardeningDisable (
          hardeningEnable ++ [ "fortify" "stackprotector" "pic" "strictoverflow" "format" "relro" "bindnow" ]
        );

      # check
      inherit doCheck enableParallelChecking checkTarget checkPhase preCheck postCheck;

      # install
      inherit dontInstall installFlags installPhase preInstall postInstall;

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
      outputSystem = pkgs.stdenv.hostPlatform.system;
      outputUnspecified = true;
      overrideAttrs = f: self.makePackage' (attrs // (f attrs));
    };

    checks = genAttrs allSystems (system:
      flattenAttrs (genAttrs [system] (crossSystem: let
        pkgs = (import nixpkgs {
          inherit system;
          crossSystem = if system != crossSystem then crossSystem else null;
        }) // this;
        this = {
          hello = self.makePackage pkgs ({ ... }: rec {
            pname = "hello";
            version = "2.10";

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://ftpmirror.gnu.org/${pname}/${pname}-${version}.tar.gz";
              narHash = "sha256-tBws6cfY1e23oTv3qu2Oc1Q6ev1YtUrgAmGS6uh7ocY=";
            };
          });

          jq = self.makePackage pkgs ({ ... }: rec {
            pname = "jq";
            version = "1.6";

            outputs = [ "bin" "doc" "man" "dev" "lib" "out" ];

            depsHostTarget = [ "oniguruma" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/stedolan/${pname}/releases/download/${pname}-${version}/${pname}-${version}.tar.gz";
              narHash = "sha256-Jb9kV1htQpc6EXTCgn0tSTCmCnxkpOBf/YQ2gCwQipc=";
            };

            doCheck = false;

            configureFlags = [
              "--bindir=${placeholder "bin"}/bin"
              "--sbindir=${placeholder "bin"}/bin"
              "--datadir=${placeholder "doc"}/share"
              "--mandir=${placeholder "man"}/share/man"
            ];
          });

          oniguruma = self.makePackage pkgs ({ ... }: rec {
            pname = "oniguruma";
            version = "6.9.5_rev1";

            depsBuildHost = [ "autoreconfHook" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/kkos/${pname}/archive/v${version}.tar.gz";
              narHash = "sha256-FErm0z2ZlxR7ctMtrCOWEPPf+i42GUW3XA+VteBApus=";
            };
          });

          m4 = self.makePackage pkgs ({ stdenv, ... }: rec {
            pname = "m4";
            version = "1.4.18";

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://ftpmirror.gnu.org/${pname}/${pname}-${version}.tar.bz2";
              narHash = "sha256-ogI4Yqq2ag8coIDfeTywz/tImM3nDFY8u4kR5dArl2o=";
            };

            doCheck = false;

            configureFlags = [ "--with-syscmd-shell=${stdenv.shell}" ];
          });

          libxslt = self.makePackage pkgs ({ libxml2, ... }: rec {
            pname = "libxslt";
            version = "1.1.34";

            outputs = [ "bin" "dev" "out" "man" "doc" ];

            depsBuildHostPropagated = [ "findXMLCatalogs" ];
            depsHostTarget = [ "libxml2" "gettext" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "http://xmlsoft.org/sources/${pname}-${version}.tar.gz";
              narHash = "sha256-EFJsKI18L8mYJvawaqjR1MqsMJTz0XssKNVsNdVW9MM=";
            };

            configureFlags = [
              "--with-libxml-prefix=${libxml2.dev}"
              "--without-debug"
              "--without-mem-debug"
              "--without-debugger"
            ];

            postFixup = ''
              moveToOutput bin/xslt-config "$dev"
              moveToOutput lib/xsltConf.sh "$dev"
              moveToOutput share/man/man1 "$bin"
            '';
          });

          xz = self.makePackage pkgs ({ ... }: rec {
            pname = "xz";
            version = "5.2.5";

            outputs = [ "bin" "dev" "out" "man" "doc" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://tukaani.org/xz/${pname}-${version}.tar.bz2";
              narHash = "sha256-lYaLeAyhlQuj+yfs71wlA+lhNVFu69PiPTu+4tu1u2I=";
            };

            preCheck = ''
              # Tests have a /bin/sh dependency...
              patchShebangs tests
            '';

            # In stdenv-linux, prevent a dependency on bootstrap-tools.
            preConfigure = "CONFIG_SHELL=/bin/sh";

            postInstall = "rm -rf $out/share/doc";
          });

          nlohmann_json = self.makePackage pkgs ({ ... }: rec {
            pname = "nlohmann_json";
            version = "3.7.3";

            nativeBuildInputs = [ "cmake" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/nlohmann/json/archive/v${version}.tar.gz";
              narHash = "sha256-PNH+swMdjrh53Ioz2D8KuERKFpKM+iBf+eHo+HvwORM=";
            };

            cmakeFlags = [
              "-DBuildTests=${if doCheck then "ON" else "OFF"}"
              "-DJSON_MultipleHeaders=ON"
            ];

            # A test causes the build to timeout https://github.com/nlohmann/json/issues/1816
            doCheck = false;

            postInstall = "rm -rf $out/lib64";
          });

          brotli = self.makePackage pkgs ({ ... }: rec {
            pname = "brotli";
            version = "1.0.7";

            outputs = [ "out" "dev" "lib" ];

            depsBuildHost = [ "cmake" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/google/brotli/archive/v${version}.tar.gz";
              narHash = "sha256-fO/rWhGarpofjSe5uK9EITw0EpsBPib1muS5xktZIaA=";
            };

            # This breaks on Darwin because our cmake hook tries to make a build folder
            # and the wonderful bazel BUILD file is already there (yay case-insensitivity?)
            prePatch = "rm BUILD";

            # Don't bother with "man" output for now,
            # it currently only makes the manpages hard to use.
            postInstall = ''
              mkdir -p $out/share/man/man{1,3}
              cp ../docs/*.1 $out/share/man/man1/
              cp ../docs/*.3 $out/share/man/man3/
            '';
          });

          editline = self.makePackage pkgs ({ ... }: rec {
            pname = "editline";
            version = "1.17.0";

            outputs = [ "out" "dev" "man" "doc" ];

            depsBuildHost = [ "autoreconfHook" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/troglobit/${pname}/archive/${version}.tar.gz";
              narHash = "sha256-ZiO8K8IiicF0b2XW9RQo+nA9Jz8UPMsaNLHKb7wgVW4=";
            };
          });

          libsodium = self.makePackage pkgs ({ ... }: rec {
            pname = "libsodium";
            version = "1.0.18";

            outputs = [ "out" "dev" ];

            src = fetchTree {
              type = "tarball";
              url = "https://download.${pname}.org/${pname}/releases/${pname}-${version}.tar.gz";
              narHash = "sha256-58vNr1SKoLKC/YBPUH5pFmCm+7dLxKukXKHP7GTUNGo=";
            };
          });

          sharutils = self.makePackage pkgs ({ ... }: rec {
            pname = "sharutils";
            version = "4.15.2";

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://ftpmirror.gnu.org/${pname}/${pname}-${version}.tar.xz";
              narHash = "sha256-YFELWBex9FtGDqT4bWhnbtgkyR0NwJWGM/e96spa4Bs=";
            };

            hardeningDisable = [ "format" ];

            depsHostTarget = [ "gettext" ];

            postPatch = let shar_sub = "\${SHAR}";
            in ''
                  substituteInPlace tests/shar-1 --replace '${shar_sub}' '${shar_sub} -s submitter'
                  substituteInPlace tests/shar-2 --replace '${shar_sub}' '${shar_sub} -s submitter'

                  substituteInPlace intl/Makefile.in --replace "AR = ar" ""
            '';
          });

          bzip2 = self.makePackage pkgs ({ ... }: rec {
            pname = "bzip2";
            version = "1.0.6.0.1";

            outputs = [ "bin" "dev" "out" "man" ];

            depsBuildHost = [ "autoreconfHook" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "http://ftp.uni-kl.de/pub/linux/suse/people/sbrabec/${pname}/tarballs/${pname}-${version}.tar.gz";
              narHash = "sha256-XbJmgxrZPzgHGLOHBa9U3l58D9rEkn6OUJ6atepcoUg=";
            };

            postPatch = ''
              sed -i -e '/<sys\\stat\.h>/s|\\|/|' bzip2.c
            '';
          });

          lzo = self.makePackage pkgs ({ ... }: rec {
            pname = "lzo";
            version = "2.10";

            src = builtins.fetchTree {
              type = "tarball";
              url = "http://www.oberhumer.com/opensource/lzo/download/${pname}-${version}.tar.gz";
              narHash = "sha256-NKNBFisxtCfm/MTmAI9pVHxMzZ+fR0GRPI9qH0Uhj/o=";
            };
          });

          libarchive = self.makePackage pkgs ({ stdenv, ... }: rec {
            pname = "libarchive";
            version = "3.4.3";

            outputs = [ "out" "lib" "dev" ];

            depsBuildHost = [ "pkgconfig" "autoreconfHook" ];
            depsHostTarget = [ "sharutils" "zlib" "bzip2" "openssl" "xz" "lzo" "zstd" "libxml2" ]
              ++ optionals stdenv.hostPlatform.isLinux [ "e2fsprogs" "attr" "acl" ];
            depsHostTargetPropagated = optionals stdenv.hostPlatform.isLinux [ "attr" "acl" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/${pname}/${pname}/archive/v${version}.tar.gz";
              narHash = "sha256-QA/mC66N1ZFUR/LqI0iDaNbncGjxgisyvWb7b+4AG/g=";
            };

            configureFlags = [ "--without-xml2" ];

            doCheck = false; # fails
          });

          boehmgc = self.makePackage pkgs ({ ... }: rec {
            pname = "boehm-gc";
            version = "8.0.4";

            outputs = [ "out" "dev" "doc" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/ivmai/bdwgc/releases/download/v${version}/gc-${version}.tar.gz";
              narHash = "sha256-Z8rvI7Z5JapHzPMruqyP4o03Mx59I0QZLTkU7ngrLJo=";
            };

            configureFlags = [ "--enable-cplusplus" "--with-libatomic-ops=none" ];
          });

          nix = self.makePackage pkgs ({ stdenv, ... }: rec {
            pname = "nix";
            version = "2.4pre20200622_334e26b";

            outputs = [ "out" "dev" "man" "doc" ];

            depsBuildHost = [
              "pkgconfig"
              "autoreconfHook"
              "autoconf-archive"
              "bison"
              "flex"
              "libxml2"
              "libxslt"
              "docbook5"
              "docbook_xsl_ns"
              "jq"
            ];
            depsHostTarget = [
              "curl"
              "openssl"
              "sqlite"
              "xz"
              "bzip2"
              "nlohmann_json"
              "brotli"
              "boost"
              "editline"
              "libsodium"
              "libarchive"
              "gtest"
            ] ++ optional stdenv.hostPlatform.isLinux "libseccomp";
            depsHostTargetPropagated = [ "boehmgc" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/NixOS/${pname}/archive/334e26bfc2ce82912602e8a0f9f9c7e0fb5c3221.tar.gz";
              narHash = "14a2yyn1ygymlci6hl5d308fs3p3m0mgcfs5dc8dn0s3lg5qvbmp";
            };

            configureFlags = [
              "--with-store-dir=/nix/store"
              "--localstatedir=/nix/"
              "--sysconfdir=/etc"
              "--disable-init-state"
              "--enable-gc"
              "--with-system=${stdenv.hostPlatform.system}"
            ];

            makeFlags = [ "profiledir=${placeholder "out"}/etc/profile.d" ];

            installFlags = [ "sysconfdir=${placeholder "out"}/etc" ];
          });

          nix2 = this.nix.overrideAttrs (_: {
            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/NixOS/nix/archive/e3a3406db833c763d6214747bfff430061337df3.tar.gz";
              narHash = "sha256-3vq2yYLOijrDNUEKRjJ3iU2e/symm2NXtq0encDWHk4=";
            };
          });
        }; in this
    )));

  };
}
