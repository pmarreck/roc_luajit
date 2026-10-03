# Lua platform

A command-line Roc platform whose programs can run Lua code on LuaJIT, built
natively (`roc build`) or for the LuaJIT backend (`roc build --target=luajit`).

```roc
app [main!] { pf: platform "path/to/luajit_backend/platforms/lua/main.roc" }

import pf.Lua
import pf.Stdout

main! = |_args| {
	doubled = Lua.eval!("return ... * 2", [Int(21)])
	Stdout.line!(Str.inspect(doubled)) # Ok(Int(42))
	Ok({})
}
```

Modules: `Lua` (`eval!`, `Value`), `Stdout`, `Stderr`, `Stdin`, `Env`, `File`
(UTF-8 text), `Path`. `main!` receives the command-line arguments without the
program name and returns `Try({}, [Exit(I32), ..])`.

## Lua values

`Lua.Value : [Nil, Bool(Bool), Int(I64), Num(F64), Str(Str), Table(List((Value, Value)))]`.
`eval!` passes its arguments as the chunk's `...` and returns its first
result, or `LuaSyntax(msg)` / `LuaRuntime(msg)`. Lua has one number type, so an
integral number within +-2^53 always comes back as `Int`; tables come back with
their keys sorted (booleans, numbers, strings) and without `Nil` values.
Functions, userdata and invalid UTF-8 strings cannot come back
(`LuaRuntime`). Every `eval!` in a run shares one environment: globals a
snippet defines stay defined for later calls, apart from the program's own
state.

## How it works

The platform has one hosted function, `Host.call!(op, request) => response`,
whose request and response are values in a small byte encoding (`Lua.encode`
and `Lua.decode` on the Roc side). Both hosts answer it with the same
`host.lua`: the native host (`host.zig`) embeds LuaJIT and `host.lua` and
forwards the bytes; for `--target=luajit`, `host.lua` is the host. Every effect
(Lua evaluation, files, environment, standard streams) therefore has one
implementation, and both builds of a program behave alike.

Build the native host with `nix develop -c ./build-host` (Linux x86_64, static
musl; it links a static LuaJIT built with internal unwinding). The tests are
`luajit_backend/tests/lua_platform_core.lua` (codec round trips and ops through
recording adapters) and `luajit_backend/tests/lua_platform_conformance` (apps
built both ways must print the same and exit alike).
