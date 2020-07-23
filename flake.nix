{
  description = "Tools to compose packages from Nixpkgs, combining callPackage and stdenv.mkDerivation";

  inputs.nixpkgs.url = "nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }: let
    inherit (nixpkgs.lib) genAttrs flatten optional optionals optionalString;
    flattenAttrs = f: builtins.listToAttrs (flatten (
      map (n:
        map (n': { name = "${n}-${n'}"; value = f.${n}.${n'}; }) (builtins.attrNames f.${n})
      ) (builtins.attrNames f)
    ));
    allSystems = [ "x86_64-linux" "i686-linux" "x86_64-darwin" "aarch64-linux" ];
  in {
    overlay = final: prev: { makePackage = self.makePackage prev; };

    makePackage = import ./make-package.nix { inherit (nixpkgs) lib; };

    makePackagesFlake = {
      systems ? allSystems
    , crossSystems ? []
    , defaultPackageName ? null
    , nixpkgs' ? nixpkgs
    }: packages: let
      defaultPackageName' = if defaultPackageName != null then defaultPackageName
                            else builtins.head (builtins.attrNames packages);

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      overlay = final: prev: builtins.mapAttrs (_: f: self.makePackage prev f) packages;

      # Memoize nixpkgs for different platforms for efficiency.
      nixpkgsFor = forAllSystems (system:
        import nixpkgs' {
          inherit system;
          overlays = [ overlay ];
        }
      );

      nixpkgsCrossFor = forAllSystems (system: forAllSystems (crossSystem:
        import nixpkgs' {
          inherit system crossSystem;
          overlays = [ overlay ];
        }
      ));

      packages' = forAllSystems (system: (builtins.mapAttrs (name: _: nixpkgsFor.${system}.${name}) packages)
        // flattenAttrs (nixpkgs.lib.genAttrs crossSystems (crossSystem: builtins.mapAttrs (
          (name: _: nixpkgsCrossFor.${system}.${crossSystem}.${name})
        ) packages)));
    in {
      inherit overlay;

      packages = packages';

      defaultPackage = forAllSystems (system: packages'.${system}.${defaultPackageName'});
    };

    checks = (self.makePackagesFlake {} {
      hello = ({ ... }: rec {
        pname = "hello";
        version = "2.10";

        src = builtins.fetchTree {
          type = "tarball";
          url = "https://ftpmirror.gnu.org/${pname}/${pname}-${version}.tar.gz";
          narHash = "sha256-tBws6cfY1e23oTv3qu2Oc1Q6ev1YtUrgAmGS6uh7ocY=";
        };
      });
    }).packages // genAttrs allSystems (system:

      flattenAttrs (genAttrs [system "x86_64-linux" "aarch64-linux"] (crossSystem: let
        packages = (import nixpkgs {
          inherit system;
          crossSystem = if system != crossSystem then crossSystem else null;
        }) // this;
        this = {
          jq = self.makePackage packages ({ ... }: rec {
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

          oniguruma = self.makePackage packages ({ ... }: rec {
            pname = "oniguruma";
            version = "6.9.5_rev1";

            depsBuildHost = [ "autoreconfHook" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://github.com/kkos/${pname}/archive/v${version}.tar.gz";
              narHash = "sha256-FErm0z2ZlxR7ctMtrCOWEPPf+i42GUW3XA+VteBApus=";
            };
          });

          m4 = self.makePackage packages ({ stdenv, ... }: rec {
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

          libxslt = self.makePackage packages ({ libxml2, ... }: rec {
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

          xz = self.makePackage packages ({ ... }: rec {
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

          nlohmann_json = self.makePackage packages ({ ... }: rec {
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

          brotli = self.makePackage packages ({ ... }: rec {
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

          editline = self.makePackage packages ({ ... }: rec {
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

          libsodium = self.makePackage packages ({ ... }: rec {
            pname = "libsodium";
            version = "1.0.18";

            outputs = [ "out" "dev" ];

            src = builtins.fetchTree {
              type = "tarball";
              url = "https://download.${pname}.org/${pname}/releases/${pname}-${version}.tar.gz";
              narHash = "sha256-58vNr1SKoLKC/YBPUH5pFmCm+7dLxKukXKHP7GTUNGo=";
            };
          });

          sharutils = self.makePackage packages ({ ... }: rec {
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

          bzip2 = self.makePackage packages ({ ... }: rec {
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

          lzo = self.makePackage packages ({ ... }: rec {
            pname = "lzo";
            version = "2.10";

            src = builtins.fetchTree {
              type = "tarball";
              url = "http://www.oberhumer.com/opensource/lzo/download/${pname}-${version}.tar.gz";
              narHash = "sha256-NKNBFisxtCfm/MTmAI9pVHxMzZ+fR0GRPI9qH0Uhj/o=";
            };
          });

          libarchive = self.makePackage packages ({ stdenv, ... }: rec {
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

          boehmgc = self.makePackage packages ({ ... }: rec {
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

          nix = self.makePackage packages ({ stdenv, ... }: rec {
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
              "--localstatedir=/nix/var"
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
