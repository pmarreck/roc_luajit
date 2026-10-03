## Lua.eval! through the Lua platform: values both ways, shared globals,
## syntax and runtime errors, unrepresentable results, plus Stdout, Env and
## File. Must print the same natively and on LuaJIT.
app [main!] { pf: platform "../../../platforms/lua/main.roc" }

import pf.Lua
import pf.Stdout
import pf.Env
import pf.File

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

main! = |args| {
	show!("args", args)
	show!("double", Lua.eval!("return ... * 2", [Int(21)]))
	show!("float", Lua.eval!("return ... / 4", [Int(1)]))
	show!("integral Num comes back as Int", Lua.eval!("return ...", [Num(3.0)]))
	show!("big int", Lua.eval!("return ...", [Int(9007199254740993)]))
	show!("string", Lua.eval!("return (...):upper() .. ' ✓'", [Str("héllo")]))
	show!("several args", Lua.eval!("local a, b, c = ... return a + b + c", [Int(1), Int(2), Num(0.5)]))
	show!("nil and bools", Lua.eval!("local a, b = ... return {a == nil, b}", [Nil, Bool(False)]))
	show!("table", Lua.eval!("return {10, 20, name = 'x', [true] = {inner = 1.5}}", []))
	show!("table in", Lua.eval!("local t = ... local s = 0 for _, v in ipairs(t) do s = s + v end return s", [Table([(Int(1), Int(5)), (Int(2), Int(6))])]))
	show!("define", Lua.eval!("function greet(n) return 'hi ' .. n end", []))
	show!("use later", Lua.eval!("return greet(...)", [Str("roc")]))
	show!("globals stay apart", Lua.eval!("return rawget(_G, 'greet') == nil", []))
	show!("syntax error", Lua.eval!("return (", []))
	show!("runtime error", Lua.eval!("error('boom', 0)", []))
	show!("function result", Lua.eval!("return print", []))
	show!("jit", Lua.eval!("return type(jit) == 'table' and jit.version:sub(1, 6)", []))
	show!("env", Env.var!("LUA_PLATFORM_TEST"))
	show!("env missing", Env.var!("LUA_PLATFORM_SURELY_UNSET"))
	path = "lua_platform_test.txt"
	show!("write", File.write_utf8!(path, "one\n"))
	show!("append", File.append_utf8!(path, "two\n"))
	show!("read", File.read_utf8!(path))
	show!("delete", File.delete!(path))
	show!("read deleted", File.read_utf8!(path))
	Ok({})
}
