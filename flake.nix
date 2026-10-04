{
	description = "Roc LIR-to-LuaJIT backend investigation and native oracle";
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/9fbb54b33e91ee4ca368e35a78e0613c720600b3";
		flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b";
		gitignore = {
			url = "github:hercules-ci/gitignore.nix/cb5e3fdca1de58ccbc3ef53de65bd372b48f567c";
			inputs.nixpkgs.follows = "nixpkgs";
		};
		# Prebuilt Rust with the cross std libraries MiniCI's glue-ABI checks
		# compile against (native musl + wasm32). Project-local, never global.
		rust-overlay = {
			url = "github:oxalica/rust-overlay/ed3a19fd0439ed618ec5fe1e12f0ba69a8be38b5";
			inputs.nixpkgs.follows = "nixpkgs";
		};
		# performance-profile: the shared complexity/timing/memory gate engine
		# behind ./cg, ./mg and ./bm (cases in profiling.json).
		performance-profiling.url = "github:pmarreck/performance_profiling/a04d62a441a5b9315e81f6277f57f7eddb9a57af";
	};
	outputs = inputs@{ self, nixpkgs, rust-overlay, ... }: let
		# Reuse upstream's declared fixed-output compiler dependencies and build.
		# This is the native reference compiler, not an implemented Lua backend.
		upstream = (import ./src/flake.nix).outputs inputs;
		systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
		forAll = nixpkgs.lib.genAttrs systems;
		luaFor = pkgs: pkgs.luajit.withPackages (lua: [ lua.cjson lua.luv ]);
		# Targets named by build.zig's run-check-glue-abi (native musl or
		# darwin triple, plus wasm32-unknown-unknown).
		rustTargets = {
			x86_64-linux = [ "x86_64-unknown-linux-musl" "wasm32-unknown-unknown" ];
			aarch64-linux = [ "aarch64-unknown-linux-musl" "wasm32-unknown-unknown" ];
			aarch64-darwin = [ "aarch64-apple-darwin" "wasm32-unknown-unknown" ];
		};
		# Tools upstream ci/*.sh checks require beyond stdenv (objdump comes from
		# mkShell's stdenv). Upstream test prerequisites only; nothing in this
		# project is written in Python.
		ciToolsFor = pkgs: [ pkgs.python3Minimal ]
			# nixpkgs marks valgrind broken on aarch64-darwin at this pin.
			++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.valgrind ];
		# This project's own test and benchmark tools: expect runs upstream
		# roc-lang/examples' expect scripts against the demos (tests/demo_expect);
		# hyperfine and jq drive bench/compare/run.
		# perf counts user-mode instructions for bench/measure (Linux).
		projectToolsFor = pkgs: [ pkgs.expect pkgs.hyperfine pkgs.jq pkgs.iproute2 pkgs.util-linux pkgs.wasmtime ] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.perf ];
		# Roc packages the basic-cli conformance tests build against, fetched once
		# by hash and unpacked, so tests run offline with
		# `roc build --replace-dep <url> <dir>/main.roc`.
		rocPackage = pkgs: { name, url, hash }: pkgs.runCommand name {
			src = pkgs.fetchurl { inherit url hash; };
			nativeBuildInputs = [ pkgs.gnutar pkgs.zstd ];
		} ''
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
		nativeLibsFor = pkgs: {
			ROC_LUAJIT_LIBSQLITE3 = "${pkgs.sqlite.out}/lib/libsqlite3${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
			ROC_LUAJIT_LIBCURL = "${pkgs.curl.out}/lib/libcurl${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
		} // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
			# Static musl LuaJIT the Lua platform's native host links
			# (luajit_backend/platforms/lua/build-host), with LuaJIT's internal
			# unwinding: a static musl link has no libgcc_eh/libunwind for its
			# default external (DWARF) unwinder.
			ROC_LUAJIT_LUAJIT_STATIC = "${pkgs.pkgsStatic.luajit.overrideAttrs (old: { makeFlags = old.makeFlags ++ [ "XCFLAGS=-DLUAJIT_NO_UNWIND" ]; })}";
		};
		rustFor = system: let
			pkgs = import nixpkgs { inherit system; overlays = [ rust-overlay.overlays.default ]; };
		in pkgs.rust-bin.stable.latest.minimal.override { targets = rustTargets.${system}; };
	in {
		packages = forAll (system: upstream.packages.${system});
		apps = forAll (system: upstream.apps.${system});
		formatter = forAll (system: upstream.formatter.${system});
		devShells = forAll (system: let pkgs = import nixpkgs { inherit system; }; in {
			default = pkgs.mkShell ({
				inputsFrom = [ upstream.devShell.${system} ];
				packages = [ (luaFor pkgs) (rustFor system) inputs.performance-profiling.packages.${system}.default ] ++ ciToolsFor pkgs ++ projectToolsFor pkgs;
			} // rocPackagesFor pkgs // nativeLibsFor pkgs);
		});
		checks = forAll (system: let pkgs = import nixpkgs { inherit system; }; in {
			# Toolchain smoke only. MiniCI/oracle tests remain an M0 deliverable.
			toolchain = pkgs.runCommand "roc-luajit-toolchain-check" {
				nativeBuildInputs = [ pkgs.zig_0_16 (luaFor pkgs) ];
				strictDeps = true;
			} ''
				test "$(zig version)" = 0.16.0
				luajit ${./luajit_backend/tests/toolchain.lua}
				mkdir -p "$out"
				touch "$out/passed"
			'';
		});
	};
}
