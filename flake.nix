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

    # compat for non-flakes Nix (taken from https://github.com/edolstra/flake-compat)
    fetchTree = builtins.fetchTree or (info:
    if info.type == "github" then
        { outPath = fetchTarball "https://api.github.com/repos/${info.owner}/${info.repo}/tarball/${info.rev}";
          rev = info.rev;
          shortRev = builtins.substring 0 7 info.rev;
          narHash = info.narHash or null;
        }
      else if info.type == "git" then
        { outPath =
            builtins.fetchGit
              ({ url = info.url; }
               // (if info ? rev then { inherit (info) rev; } else {})
               // (if info ? ref then { inherit (info) ref; } else {})
              );
          rev = info.rev;
          shortRev = builtins.substring 0 7 info.rev;
          narHash = info.narHash or null;
        }
      else if info.type == "tarball" then
        { outPath =
            builtins.fetchTarball
              ({
                url = info.url;
              }
               // (if (info ? narHash && (builtins.substring 0 7 info.narHash) == "sha256-") then { sha256 = builtins.substring 7 (builtins.stringLength info.narHash - 7) info.narHash; } else {})
              );
          narHash = info.narHash or null;
        }
      else
        # FIXME: add Mercurial, tarball inputs.
        throw "flake input has unsupported input type '${info.type}'"
    );
  in {
    overlay = final: prev: { makePackage = self.makePackage prev; };

    makePackage = import ./make-package.nix { inherit (nixpkgs) lib; };

    makePackagesFlake = {
      systems ? allSystems
    , crossSystems ? []
    , nixpkgs' ? nixpkgs
    , defaultPackageName ? null
    }: packages:  let
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
      defaultPackageName' = if defaultPackageName != null then defaultPackageName
                            else builtins.head (builtins.attrNames packages);
      packages' = self.makePackagesFlake' { inherit systems crossSystems nixpkgs'; } packages;
    in  {
      # inherit overlay;

      packages = packages';

      defaultPackage = forAllSystems (system: packages'.${system}.${defaultPackageName'});
    };

    makePackagesFlake' = {
      systems ? allSystems
    , crossSystems ? []
    , nixpkgs' ? nixpkgs
    }: packages: let
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);

      overlayFun = system: final: prev: builtins.mapAttrs (name: f:
        if builtins.isFunction f then self.makePackage final f
        else if f ? packageFun then self.makePackage final f.packageFun
        else if f ? defaultPackage && builtins.hasAttr system f.defaultPackage && f.defaultPackage.${system} ? packageFun then self.makePackage final f.defaultPackage.${system}.packageFun
        else throw "Package entry for '${name}' must either be a function for makePackage, or a flake made with makePackage, got type ${builtins.typeOf f}") packages;

      # Memoize nixpkgs for different platforms for efficiency.
      nixpkgsFor = forAllSystems (system:
        import nixpkgs' {
          inherit system;
          overlays = [ (overlayFun system) ];
        }
      );

      nixpkgsCrossFor = forAllSystems (system: forAllSystems (crossSystem:
        import nixpkgs' {
          inherit system crossSystem;
          overlays = [ (overlayFun system) ];
        }
      ));
    in forAllSystems (system: (builtins.mapAttrs (name: _: nixpkgsFor.${system}.${name}) packages)
        // flattenAttrs (nixpkgs.lib.genAttrs crossSystems (crossSystem: builtins.mapAttrs (
          (name: _: nixpkgsCrossFor.${system}.${crossSystem}.${name})
        ) packages)));

    checks = let
      oniguruma_ = self.makePackagesFlake {} {
        oniguruma = { ... }: rec {
          pname = "oniguruma";
          version = "6.9.5_rev1";

          nativeBuildInputs = [
            "autoreconfHook"
          ];

          src = fetchTree {
            type = "tarball";
            url = "https://github.com/kkos/${pname}/archive/v${version}.tar.gz";
            narHash = "sha256-FErm0z2ZlxR7ctMtrCOWEPPf+i42GUW3XA+VteBApus=";
          };
        };
      };
    in self.makePackagesFlake' { } {
      jq_ = { stdenv, ... }: rec {
        pname = "jq";
        version = "1.6";

        outputs = [ "bin" "doc" "man" "dev" "lib" "out" ];

        buildInputs = [
          oniguruma_
        ];

        src = fetchTree {
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
        ]
        # jq is linked to libjq:
        ++ stdenv.lib.optional (!stdenv.isDarwin) "LDFLAGS=-Wl,-rpath,\\\${libdir}";
      };

      hello_ = ({ ... }: rec {
        pname = "hello";
        version = "2.10";

        src = fetchTree {
          type = "tarball";
          url = "https://ftpmirror.gnu.org/${pname}/${pname}-${version}.tar.gz";
          narHash = "sha256-tBws6cfY1e23oTv3qu2Oc1Q6ev1YtUrgAmGS6uh7ocY=";
        };
      });

      zlib_ = { stdenv, ... }: rec {
        pname = "zlib";
        version = "1.2.11";

        outputs = [ "out" "dev" ];
        setOutputFlags = false;
        outputDoc = "dev"; # single tiny man3 page

        src = fetchTree {
          type = "tarball";
          url = "https://www.zlib.net/fossils/${pname}-${version}.tar.gz";
          narHash = "sha256-AQIoy96jcdmKs/F4GVqDFXxcZ7c66GF+yalHg3ALEyU=";
        };

        configurePlatforms = [];

        postPatch = stdenv.lib.optionalString stdenv.hostPlatform.isDarwin ''
          substituteInPlace configure \
            --replace '/usr/bin/libtool' 'ar' \
            --replace 'AR="libtool"' 'AR="ar"' \
            --replace 'ARFLAGS="-o"' 'ARFLAGS="-r"'
        '';

        makeFlags = [
          "PREFIX=${stdenv.cc.targetPrefix}"
          "SHARED_MODE=1"
        ];
      };

      libxslt_ = { libxml2, ... }: rec {
        pname = "libxslt";
        version = "1.1.34";

        outputs = [ "bin" "dev" "out" "man" "doc" ];

        propagatedBuildInputs = [
          "findXMLCatalogs"
        ];
        buildInputs = [
          "libxml2"
          "gettext"
        ];

        src = fetchTree {
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
      };

      xz_ = { ... }: rec {
        pname = "xz";
        version = "5.2.5";

        outputs = [ "bin" "dev" "out" "man" "doc" ];

        src = fetchTree {
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
      };

      nlohmann_json_ = { ... }: rec {
        pname = "nlohmann_json";
        version = "3.7.3";

        nativeBuildInputs = [
          "cmake"
        ];

        src = fetchTree {
          type = "github";
          owner = "nlohmann";
          repo = "json";
          rev = "e7b3b40b5a95bc74b9a7f662830a27c49ffc01b4";
        };

        cmakeFlags = [
          "-DBuildTests=${if doCheck then "ON" else "OFF"}"
          "-DJSON_MultipleHeaders=ON"
        ];

        # A test causes the build to timeout https://github.com/nlohmann/json/issues/1816
        doCheck = false;

        postInstall = "rm -rf $out/lib64";
      };

      brotli_ = { ... }: rec {
        pname = "brotli";
        version = "1.0.7";

        outputs = [ "out" "dev" "lib" ];

        nativeBuildInputs = [
          "cmake"
        ];

        src = fetchTree {
          type = "github";
          owner = "google";
          repo = "brotli";
          rev = "d6d98957ca8ccb1ef45922e978bb10efca0ea541";
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
      };

      editline_ = { ... }: rec {
        pname = "editline";
        version = "1.17.0";

        outputs = [ "out" "dev" "man" "doc" ];

        nativeBuildInputs = [
          "autoreconfHook"
        ];

        src = fetchTree {
          type = "github";
          owner = "troglobit";
          repo = "editline";
          rev = "02cccd1e87b818cc0ac2ffab7b4bcc3e6cd9ba5a";
        };
      };

      libsodium_ = { ... }: rec {
        pname = "libsodium";
        version = "1.0.18";

        outputs = [ "out" "dev" ];

        src = fetchTree {
          type = "tarball";
          url = "https://download.${pname}.org/${pname}/releases/${pname}-${version}.tar.gz";
          narHash = "sha256-58vNr1SKoLKC/YBPUH5pFmCm+7dLxKukXKHP7GTUNGo=";
        };
      };

      bzip2_ = { ... }: rec {
        pname = "bzip2";
        version = "1.0.6.0.1";

        outputs = [ "bin" "dev" "out" "man" ];

        nativeBuildInputs = [
          "autoreconfHook"
        ];

        src = fetchTree {
          type = "tarball";
          url = "http://ftp.uni-kl.de/pub/linux/suse/people/sbrabec/${pname}/tarballs/${pname}-${version}.tar.gz";
          narHash = "sha256-XbJmgxrZPzgHGLOHBa9U3l58D9rEkn6OUJ6atepcoUg=";
        };

        postPatch = ''
          sed -i -e '/<sys\\stat\.h>/s|\\|/|' bzip2.c
        '';
      };

      lzo_ = { ... }: rec {
        pname = "lzo";
        version = "2.10";

        src = fetchTree {
          type = "tarball";
          url = "http://www.oberhumer.com/opensource/lzo/download/${pname}-${version}.tar.gz";
          narHash = "sha256-NKNBFisxtCfm/MTmAI9pVHxMzZ+fR0GRPI9qH0Uhj/o=";
        };
      };

      boehmgc_ = { ... }: rec {
        pname = "boehm-gc";
        version = "8.0.4";

        outputs = [ "out" "dev" "doc" ];

        src = fetchTree {
          type = "tarball";
          url = "https://github.com/ivmai/bdwgc/releases/download/v${version}/gc-${version}.tar.gz";
          narHash = "sha256-Z8rvI7Z5JapHzPMruqyP4o03Mx59I0QZLTkU7ngrLJo=";
        };

        configureFlags = [ "--enable-cplusplus" "--with-libatomic-ops=none" ];
      };

      help2man_ = { stdenv, perlPackages, ... }: rec {
        pname = "help2man";
        version = "1.47.15";

        src = fetchTree {
          type = "tarball";
          url = "https://ftpmirror.gnu.org/${pname}/${pname}-${version}.tar.xz";
          narHash = "sha256-qiVZ7aslQsbflemC1a8b28x9QSgC2WWIHA4ajiraD5I=";
        };

        nativeBuildInputs = [
          "gettext"
          "perlPackages.perl"
          "perlPackages.LocaleGettext"
        ];
        buildInputs = [
          "perlPackages.perl"
          "perlPackages.LocaleGettext"
        ];

        doCheck = false; # target `check' is missing

        # We don't use makeWrapper here because it uses substitutions our
        # bootstrap shell can't handle.
        postInstall = ''
          mv $out/bin/help2man $out/bin/.help2man-wrapped
          cat > $out/bin/help2man <<EOF
          #! $SHELL -e
          export PERL5LIB=\''${PERL5LIB:+:}${perlPackages.LocaleGettext}/${perlPackages.perl.libPrefix}
          exec -a \$0 $out/bin/.help2man-wrapped "\$@"
          EOF
          chmod +x $out/bin/help2man
        '';
      };

      sqlite_ = { stdenv, zlib_, ... }: rec {
        pname = "sqlite";
        version = "3.32.2";

        outputs = [ "bin" "dev" "out" ];

        src = fetchTree {
          type = "tarball";
          url = "https://sqlite.org/2020/sqlite-autoconf-3320300.tar.gz";
          narHash = "sha256-4oPN/1njvKfqm0D4YWRuxTR20o0bLy418mp6+F2Y+3Q=";
        };

        nativeBuildInputs = [
          zlib_
          "readline"
          "ncurses"
        ];

        configureFlags = [
          "--enable-threadsafe"
          "--enable-readline"
        ];

        doCheck = false; # fails to link against tcl

        postInstall = ''
          # Do not contaminate dependent libtool-based projects with sqlite dependencies.
          sed -i $out/lib/libsqlite3.la -e "s/dependency_libs=.*/dependency_libs='''/"
        '';
      };

      curl_ = { stdenv, openssl, libidn, c-ares, libkrb5, ... }: rec {
        pname = "curl";
        version = "7.70.0";

        outputs = [ "bin" "dev" "out" "man" "devdoc" ];

        nativeBuildInputs = [
          "pkgconfig"
          "perl"
        ];
        buildInputs = [
          "nghttp2"
          "libidn"
          "zlib_"
          "brotli_"
          "c-ares"
          "openssl"
          "libkrb5"
        ];

        src = fetchTree {
          type = "tarball";
          url = "https://curl.haxx.se/download/${pname}-${version}.tar.bz2";
          narHash = "sha256-VG+ppEPF7cDjfJoo0S5XCZbjKgv2Qz+k3hnFC3ao5gc=";
        };

        # for the second line see https://curl.haxx.se/mail/tracker-2014-03/0087.html
        preConfigure = ''
          sed -e 's|/usr/bin|/no-such-path|g' -i.bak configure
          rm src/tool_hugehelp.c
        '';

        configureFlags = [
          "--without-ca-bundle"
          "--without-ca-path"
          "--with-ca-fallback"
          "--disable-manual"
          "--with-ssl=${openssl.dev}"
          "--with-libidn=${libidn.dev}"
          "--with-brotli"
          "--enable-ares=${c-ares}"
          "--with-gssapi=${libkrb5.dev}"
        ]
        # For the 'urandom', maybe it should be a cross-system option
        ++ stdenv.lib.optional (stdenv.hostPlatform != stdenv.buildPlatform)
          "--with-random=/dev/urandom";

        environment.CXX = "${stdenv.cc.targetPrefix}c++";
        environment.CXXCPP = "${stdenv.cc.targetPrefix}c++ -E";

        doCheck = false; # expensive, fails

        postInstall = ''
          moveToOutput bin/curl-config "$dev"

          # Install completions
          make -C scripts install
        '';
      };

      nix_ = { stdenv, libxslt_, ... }: rec {
        pname = "nix";
        version = "2.4pre20200622_334e26b";

        outputs = [ "out" "dev" "man" "doc" ];

        nativeBuildInputs = [
          "pkgconfig"
          "autoreconfHook"
          "autoconf-archive"
          "bison"
          "flex"
          "libxml2"
          libxslt_
          "docbook5"
          "docbook_xsl_ns"
          "jq_"
        ];
        buildInputs = [
          "curl_"
          "openssl"
          "sqlite_"
          "xz_"
          "bzip2_"
          "zlib_"
          "nlohmann_json_"
          "brotli_"
          "boost"
          "editline_"
          "libsodium_"
          "libarchive"
          "gtest"
        ] ++ optional stdenv.hostPlatform.isLinux "libseccomp";
        propagatedBuildInputs = [
          "boehmgc_"
        ];

        src = fetchTree {
          type = "github";
          owner = "NixOS";
          repo = "nix";
          rev = "334e26bfc2ce82912602e8a0f9f9c7e0fb5c3221";
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
      };
    };

  };
}
