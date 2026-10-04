# basic-cli on WASI

A WASI host for [basic-cli](https://github.com/roc-lang/basic-cli) 0.23.0, so an
ordinary basic-cli app can be built for `wasm32` and run under a WASI runtime
(wasmtime) with no change to its source.

```sh
# in the project dev shell (nix develop)
luajit_backend/platforms/wasi_basic_cli/build /tmp/wasi_basic_cli
roc build --target=wasm32 --opt=speed \
	--replace-dep https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst /tmp/wasi_basic_cli/main.roc \
	app.roc --output=app.wasm
wasmtime run -S inherit-env=y --dir=/ app.wasm ARGS...
```

`build` copies basic-cli's platform sources, adds a `wasm32` target
(`host.wasm` plus the app, exporting `_start`), generates Zig glue for that
platform (`roc glue` with ZigGlue), and compiles `host.zig` for `wasm32-wasi`
against it.

## What works

Standard streams, arguments, the environment and working directory, locale,
clocks, randomness and sleep, whole-file reads and writes, file metadata,
buffered file readers, directories, path type, absolute and canonical paths,
temporary directories, and file and directory copies. Behavior follows
basic-cli's Rust host and its LuaJIT port (`src/backend/lua/hosts/basic_cli_0_23_0.lua`):
the same results, error values, messages and exit codes.

The host reaches files through the runtime's preopened directories: run with
`--dir=/` (the whole filesystem) or a narrower directory. Relative paths are
resolved against `$PWD`, which `-S inherit-env=y` passes along.

## What WASI preview1 cannot provide

Processes (`Cmd`), sockets (`Tcp`, `Http`), terminal raw mode (`Tty`), and
permission bits (`File.is_executable!`; readable and writable mean the file
opens that way). SQLite is not built for wasm yet. A program that calls one of
these hosted functions prints `basic-cli's WASI host does not provide hosted
function <name>` and exits with status 1. `File.time_created!` reports
Unsupported, as native basic-cli does on filesystems without birth times, and
`Env.exe_path!` reports ExePathUnavailable.

## Tests

`luajit_backend/tests/basic_cli_conformance candidate=wasm` runs basic-cli's
own examples and test cases (and `luajit_backend/tests/basic_cli_extra`)
natively and on this host and compares stdout, stderr and exit status. It is
part of `./test-luajit`, with a ratchet on the unsupported count
(`luajit_backend/tests/basic_cli_wasi_unsupported_ratchet`).
