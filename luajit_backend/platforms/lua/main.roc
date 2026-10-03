## A command-line platform whose programs can run Lua code (LuaJIT) through
## `Lua.eval!`, built natively or for `--target=luajit`. Both builds run every
## effect through one platform.lua (see Host.roc).
platform ""
	requires {
		## The program's command-line arguments (without the program name).
		main! : List(Str) => Try({}, [Exit(I32), ..])
	}
	exposes [Lua, Stdout, Stderr, Stdin, Env, File, Path]
	packages {}
	provides { "roc_main": main_for_host! }
	hosted {
		"lua_platform_host_call": Host.call!,
	}
	targets: {
		inputs_dir: "targets/",
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Host
import Lua
import Stdout
import Stderr
import Stdin
import Env
import File
import Path

main_for_host! : List(Str) => I32
main_for_host! = |args|
	match main!(args) {
		Ok({}) => 0
		Err(Exit(code)) => code
		Err(other) => {
			Stderr.line!("Program exited with error: ${Str.inspect(other)}")
			1
		}
	}
