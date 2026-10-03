# Trying the LuaJIT backend

`roc build --target=luajit` turns a Roc app into one self-contained Lua file that runs on LuaJIT 2.1. The runtime is embedded in that file, and so is the host for the platforms this repository bundles a host for. Design notes live in `ARCHITECTURE.md`; the plan and progress in `PLAN.md`.

## Build roc

From the repository root, inside the project dev shell:

```sh
nix develop -c zig build roc
```

That writes `zig-out/bin/roc`. `./test-luajit` rebuilds the same binary in Debug mode.

## A basic-cli app

Save this as `hello.roc`:

```roc
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.OsStr
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |args| {
	Stdout.line!("Hello from Roc on LuaJIT! Arguments: ${List.len(args).to_str()}")?
	for arg in args {
		Stdout.line!("  ${OsStr.display(arg)}")?
	}
	Ok({})
}
```

Then:

```sh
zig-out/bin/roc build --target=luajit hello.roc --output=hello.lua
luajit hello.lua alpha "two words"
```

Output, measured on 2026-10-01 (Linux x86_64):

```
Hello from Roc on LuaJIT! Arguments: 2
  alpha
  two words
```

The first build downloads basic-cli 0.23.0 into roc's package cache (21 s here); later builds of this app took 0.8 s. The output file starts with `#!/usr/bin/env luajit` and is executable, so `./hello.lua` works too.

roc recognizes the platform by a SHA-256 of its `.roc` sources and uses the matching bundled host in `src/backend/lua/hosts/`. A platform with its own `host.lua` beside its `main.roc` uses that instead. Any other platform is an error that prints the platform's hash.

## More to try

- `luajit_backend/demos/basic-cli/examples/`: basic-cli's own examples (they build with the command above).
- `luajit_backend/demos/roc-lang-examples/` and `luajit_backend/demos/exercism/`: plain Roc programs from roc-lang/examples and the Exercism Roc track.

## Not there yet

- basic-cli: every hosted function is implemented and every upstream example case that runs on Linux agrees with the native build. HTTP and SQLite load libcurl and libsqlite3 at first use (`ROC_LUAJIT_LIBCURL` and `ROC_LUAJIT_LIBSQLITE3` name them, as the project's dev shell does, else the system's copies are used).
- The basic-cli host's file and directory calls use Linux structures (`statx`, Linux `dirent`); macOS is untested.
- Speed: slower than native builds, most of all for Dict, List and Dec code (Dec arithmetic measured about 4x native, Dict operations about 18x). `PLAN.md` has the current numbers.
