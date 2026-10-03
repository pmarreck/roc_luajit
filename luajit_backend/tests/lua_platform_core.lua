-- The Lua platform's shared core (luajit_backend/platforms/lua/host.lua):
-- the LuaValue byte codec both hosts and the Roc side agree on, `eval`, and
-- the effect ops, run against recording I/O adapters.
--   * decode(encode(v)) == v over canonical values (exhaustive scalars,
--     seeded random nested tables), and encode(decode(b)) == b over the bytes
--     the Roc side produces for them;
--   * documented canonicalization: Lua has one number type, so an integral
--     Num within +-2^53 comes back as Int; table keys come back sorted;
--   * malformed bytes are rejected, never misread.
-- Run with: luajit luajit_backend/tests/lua_platform_core.lua
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local P = dofile(here .. "/../platforms/lua/host.lua")
local ffi = require("ffi")

local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		if failures <= 25 then io.stderr:write(("FAIL %s: got %s, want %s\n"):format(label, tostring(got), tostring(want))) end
	end
end

-- Byte builders mirroring the codec (an independent spelling of the format).
local function u32(n) return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256) end
local function i64(n)
	local u = ffi.cast("uint64_t", ffi.cast("int64_t", n))
	local out = {}
	for i = 1, 8 do out[i] = string.char(tonumber(u % 256)); u = u / 256 end
	return table.concat(out)
end
local function f64(x)
	local b = ffi.new("double[1]", x)
	return ffi.string(b, 8)
end
local B = {
	nil_ = "\0", f = "\1", t = "\2",
	int = function(n) return "\3" .. i64(n) end,
	num = function(x) return "\4" .. f64(x) end,
	str = function(s) return "\5" .. u32(#s) .. s end,
	tab = function(pairs_) local out = { "\6", u32(#pairs_ / 2) } for _, p in ipairs(pairs_) do out[#out + 1] = p end return table.concat(out) end,
}

-- Scalars: bytes -> Lua value -> bytes is the identity on canonical bytes.
local scalar_bytes = {
	B.nil_, B.f, B.t, B.int(0), B.int(1), B.int(-1), B.int(2 ^ 53 - 1), B.int(-(2 ^ 53) + 1),
	B.int(ffi.new("int64_t", 2 ^ 53) + 1), B.int(-0x7fffffffffffffffLL - 1), B.int(0x7fffffffffffffffLL),
	B.num(0.5), B.num(-1.25), B.num(1e300), B.num(1 / 0), B.num(-1 / 0), B.num(2 ^ 53 + 2), B.num(5e-324),
	B.str(""), B.str("a"), B.str("héllo ✓"), B.str(string.rep("x", 70000)),
}
for i, b in ipairs(scalar_bytes) do
	local ok, v = pcall(P.decode, b)
	check(("scalar %d decodes"):format(i), ok, true)
	if ok then check(("scalar %d round trip"):format(i), P.encode(v), b) end
end

-- Canonicalization.
check("integral Num comes back as Int", P.encode(P.decode(B.num(3))), B.int(3))
check("negative zero is a Num", P.encode(-0.0), B.num(-0.0))
check("NaN is a Num", P.encode(0 / 0):sub(1, 1), "\4")
check("table keys sort by type then value", P.encode({ b = 1, [2] = true, a = false, [true] = 0, [-1] = "x" }),
	B.tab({ B.t, B.int(0), B.int(-1), B.str("x"), B.int(2), B.t, B.str("a"), B.f, B.str("b"), B.int(1) }))
check("nil-valued pairs vanish", P.encode(P.decode(B.tab({ B.str("k"), B.nil_ }))), B.tab({}))

-- Errors on values Roc cannot hold.
-- Each rejection must say why (a stack overflow from a missed cycle check
-- would also fail, for the wrong reason).
local function rejects(label, v, reason)
	local ok, err = pcall(P.encode, v)
	check(label .. " rejected", ok, false)
	check(label .. " says why", type(err) == "string" and err:find(reason, 1, true) ~= nil, true)
end
rejects("function", print, "type function")
rejects("invalid UTF-8", "\xff\xfe", "UTF-8")
rejects("uint64 past I64", 0xffffffffffffffffULL, "uint64")
local cyc = {}
cyc.self = cyc
rejects("cycle", cyc, "contains itself")
for _, bad in ipairs({ "", "\7", "\3\1\2", "\5" .. u32(5) .. "ab", "\6" .. u32(1) .. B.t, B.t .. "x" }) do
	check(("malformed %q rejected"):format(bad), (pcall(P.decode, bad)), false)
end

-- Seeded random nested values: decode(encode(v)) == v, compared through
-- the canonical bytes (encode is checked against the independent builders
-- above, so equal bytes mean equal values).
math.randomseed(1002)
local function random_value(depth)
	local k = math.random(depth > 3 and 6 or 7)
	if k == 1 then return math.random(2) == 1 end
	if k == 2 then return math.random(-1e6, 1e6) end
	if k == 3 then return math.random() * 1e6 + 0.5 end
	if k == 4 then local t = {} for i = 1, math.random(0, 12) do t[i] = string.char(math.random(32, 126)) end return table.concat(t) end
	if k == 5 then return ffi.new("int64_t", math.random(-1e9, 1e9)) * 1000003 end
	if k == 6 then return "✓" end
	local t = {}
	for _ = 1, math.random(0, 5) do
		local key = random_value(9)
		if key ~= nil and not (type(key) == "number" and key ~= key) then t[type(key) == "cdata" and tonumber(key) or key] = random_value(depth + 1) end
	end
	return t
end
for i = 1, 3000 do
	local v = random_value(0)
	local b = P.encode(v)
	check(("random %d round trip"):format(i), P.encode(P.decode(b)), b)
end

-- Ops through recording adapters.
local function recorder(stdin_lines, env, files)
	local rec = { out = {}, err = {}, files = files or {} }
	rec.ports = {
		write_stdout = function(s) rec.out[#rec.out + 1] = s end,
		write_stderr = function(s) rec.err[#rec.err + 1] = s end,
		read_stdin_line = function() return table.remove(stdin_lines or {}, 1) end,
		getenv = function(name) return (env or {})[name] end,
		read_file = function(path) local c = rec.files[path] if c then return c end return nil, "NotFound" end,
		write_file = function(path, data, append) rec.files[path] = (append and rec.files[path] or "") .. data return true end,
		delete_file = function(path) if rec.files[path] == nil then return nil, "NotFound" end rec.files[path] = nil return true end,
	}
	rec.core = P.new(rec.ports)
	return rec
end
local function call(rec, op, ...)
	return P.decode(rec.core.dispatch(op, P.encode({ ... })))
end

local r = recorder({ "first", "second" }, { HOME = "/home/x" }, { ["/a.txt"] = "hello" })
local res = call(r, "eval", "return ... * 2", 21)
check("eval doubles", res.value, 42)
res = call(r, "eval", "greeting = 'hi' return nil", nil)
check("eval nil result is ok", res.ok, true)
check("eval nil result has no value", res.value, nil)
res = call(r, "eval", "return greeting .. '!'")
check("globals persist between evals", res.value, "hi!")
check("eval globals stay out of the host's", rawget(_G, "greeting"), nil)
res = call(r, "eval", "return {1, 2, x = {y = true}}")
check("eval table", P.encode(res.value), P.encode({ 1, 2, x = { y = true } }))
res = call(r, "eval", "return (")
check("syntax error kind", res.err, "syntax")
check("syntax error message", type(res.msg), "string")
res = call(r, "eval", "error('boom', 0)")
check("runtime error kind", res.err, "runtime")
check("runtime error message", res.msg, "boom")
res = call(r, "eval", "return print")
check("unrepresentable result is a runtime error", res.err, "runtime")
call(r, "stdout_line", "out line")
call(r, "stderr_line", "err line")
call(r, "stdout_write", "no newline")
check("stdout writes", table.concat(r.out), "out line\nno newline")
check("stderr writes", table.concat(r.err), "err line\n")
check("stdin first", call(r, "stdin_line").value, "first")
check("stdin second", call(r, "stdin_line").value, "second")
check("stdin end", call(r, "stdin_line").eof, true)
check("env present", call(r, "env_var", "HOME").value, "/home/x")
check("env missing", call(r, "env_var", "NOPE").missing, true)
check("file read", call(r, "file_read", "/a.txt").value, "hello")
check("file read missing", call(r, "file_read", "/b.txt").err, "NotFound")
check("file write", call(r, "file_write", "/b.txt", "new").ok, true)
check("file append", call(r, "file_append", "/b.txt", "er").ok, true)
check("file written", r.files["/b.txt"], "newer")
check("file delete", call(r, "file_delete", "/b.txt").ok, true)
check("file delete missing", call(r, "file_delete", "/b.txt").err, "NotFound")
check("unknown op is a runtime error", (pcall(r.core.dispatch, "nope", P.encode({}))), false)

if failures == 0 then
	print("lua_platform_core: all passed")
	os.exit(0)
end
print(("lua_platform_core: %d failed"):format(failures))
os.exit(1)
