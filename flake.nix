{
  description = "Standalone Roc-to-LuaJIT compiler and backend tests";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/9fbb54b33e91ee4ca368e35a78e0613c720600b3";
    flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b";
    performance-profiling.url = "github:pmarreck/performance_profiling/a04d62a441a5b9315e81f6277f57f7eddb9a57af";
  };
  outputs =
    {
      nixpkgs,
      flake-utils,
      performance-profiling,
      ...
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        rocPackage =
          pkgs:
          {
            name,
            url,
            hash,
          }:
          pkgs.runCommand name
            {
              src = pkgs.fetchurl { inherit url hash; };
              nativeBuildInputs = [
                pkgs.gnutar
                pkgs.zstd
              ];
            }
            ''
              mkdir -p "$out"
              tar --zstd -xf "$src" -C "$out"
            '';
        rocPackagesFor = pkgs: {
          ROC_LUAJIT_BASIC_CLI_0_23_0 = rocPackage pkgs {
            name = "roc-basic-cli-0.23.0";
            url = "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst";
            hash = "sha256-4VgiMf8RF0N2DQSZemn+7CHqJ+F9dVS01Fuheh0kezY=";
          };
          ROC_LUAJIT_ROC_HTTP_1_0_0 = rocPackage pkgs {
            name = "roc-http-1.0.0";
            url = "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst";
            hash = "sha256-6e+qlQ5y9vds326vAEJFcvppsEumEnMjV6wEU2ePArQ=";
          };
        };
        # Native libraries the LuaJIT hosts load through the FFI, by absolute
        # path (the hosts read these variables before trying system names).
        nativeLibsFor =
          pkgs:
          {
            ROC_LUAJIT_LIBSQLITE3 = "${pkgs.sqlite.out}/lib/libsqlite3${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
            ROC_LUAJIT_LIBCURL = "${pkgs.curl.out}/lib/libcurl${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            # Static musl LuaJIT the Lua platform's native host links
            # (luajit_backend/platforms/lua/build-host), with LuaJIT's internal
            # unwinding: a static musl link has no libgcc_eh/libunwind for its
            # default external (DWARF) unwinder.
            ROC_LUAJIT_LUAJIT_STATIC = "${pkgs.pkgsStatic.luajit.overrideAttrs (old: {
              makeFlags = old.makeFlags ++ [ "XCFLAGS=-DLUAJIT_NO_UNWIND" ];
            })}";
          };

      in
      {
        devShells.default = pkgs.mkShell (
          {
            packages =
              with pkgs;
              [
                python3Minimal
                zig_0_16
                bash
                coreutils
                git
                jq
                expect
                hyperfine
                wasmtime
                curl
                sqlite
                (luajit.withPackages (lua: [
                  lua.cjson
                  lua.luv
                ]))
                performance-profiling.packages.${system}.default
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.util-linux
                pkgs.iproute2
                pkgs.perf
              ];
          }
          // rocPackagesFor pkgs
          // nativeLibsFor pkgs
        );
        formatter = pkgs.nixfmt;
      }
    );
}
