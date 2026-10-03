-- Str values built by concatenation: views into append-only buffers must
-- behave exactly like the plain Lua strings they stand for. Random concat
-- histories (seeded, reproducible) append to the newest value and to older
-- ones alike, and every value ever produced is compared with a reference
-- built by plain `..`. Run with: luajit luajit_backend/tests/runtime_strings.lua
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = here .. "/../../src/backend/lua/"
local W = dofile(src .. "wide.lua")
local rt = assert(loadfile(src .. "runtime.lua"))(W, dofile(src .. "int128.lua")(W), dofile(src .. "list.lua"), dofile(src .. "float.lua"), dofile(src .. "sort.lua"), dofile(src .. "numparse.lua"), dofile(src .. "fmath.lua"), dofile(src .. "simd.lua"), dofile(src .. "crypto.lua"))

local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		if failures <= 20 then
			io.stderr:write(("FAIL %s: got %s, want %s\n"):format(label, tostring(got), tostring(want)))
		end
	end
end

-- Park-Miller: reproducible without depending on math.random's generator.
local seed = 20261001
local function rand(n)
	seed = seed * 16807 % 2147483647
	return seed % n
end
local pieces = { "", "a", "bc", "héllo", "\0\1\2", ("x"):rep(40), ("long piece "):rep(9) }

for history = 1, 200 do
	local values, refs = { "" }, { "" }
	for step = 1, 120 do
		-- Mostly extend the newest value; sometimes an older one, or join two.
		local i = rand(4) == 0 and rand(#values) + 1 or #values
		local right, right_ref
		if rand(6) == 0 then
			local j = rand(#values) + 1
			right, right_ref = values[j], refs[j]
		else
			right = pieces[rand(#pieces) + 1]
			right_ref = right
		end
		values[#values + 1] = rt.str_concat(values[i], right)
		refs[#refs + 1] = refs[i] .. right_ref
		local label = ("history %d step %d"):format(history, step)
		check(label .. " length", rt.str_count_utf8_bytes(values[#values]), 0ULL + #refs[#refs])
	end
	for k = 1, #values do
		check(("history %d value %d"):format(history, k), rt.str(values[k]), refs[k])
		check(("history %d value %d is_eq"):format(history, k), rt.str_is_eq(values[k], refs[k]), true)
	end
end

-- Extending the newest value appends to its buffer in place; extending an
-- older one copies its prefix to a new buffer, leaving the newer value intact.
local base = rt.str_concat(("x"):rep(100), "y")
check("long concat is a view", type(base), "table")
local tip = rt.str_concat(base, "z")
check("tip append shares the buffer", tip.b, base.b)
local branch = rt.str_concat(base, "w")
check("non-tip append copies", branch.b ~= base.b, true)
check("tip value intact", rt.str(tip), ("x"):rep(100) .. "yz")
check("branch value", rt.str(branch), ("x"):rep(100) .. "yw")
check("short concat stays a string", type(rt.str_concat("ab", "cd")), "string")

-- Integer to_str returns an unformatted number leaf, not an interned Lua
-- string: concatenation formats it straight into the buffer, and every other
-- operation (through rt.str) formats it once. Interning millions of
-- short-lived number strings made str_build's cost grow super-linearly in
-- LuaJIT's string table (ARCHITECTURE.md). Leaves must behave exactly like
-- the strings they stand for, as either operand and inside host values.
local ffi = require("ffi")
local int_cases = {
	{ "u64_to_str", 0, "0" }, { "u64_to_str", 1234567, "1234567" }, { "u64_to_str", 2 ^ 53 - 1, "9007199254740991" },
	{ "u64_to_str", ffi.new("uint64_t", 18446744073709551615ULL), "18446744073709551615" },
	{ "i64_to_str", -42, "-42" }, { "i64_to_str", ffi.new("int64_t", -9223372036854775807LL - 1), "-9223372036854775808" },
	{ "i32_to_str", -2147483648, "-2147483648" }, { "u8_to_str", 255, "255" }, { "i16_to_str", -1, "-1" },
}
-- A Lua-number integer's to_str is the number itself (no allocation, so
-- nothing depends on LuaJIT sinking a table); int64/uint64 cdata keep a leaf
-- table, which formats without the LL/ULL suffix.
for _, c in ipairs(int_cases) do
	local leaf = rt[c[1]](c[2])
	check(c[1] .. " " .. c[3] .. " representation", type(leaf), type(c[2]) == "number" and "number" or "table")
	check(c[1] .. " " .. c[3] .. " formats", rt.str(leaf), c[3])
	check(c[1] .. " " .. c[3] .. " length", rt.str_count_utf8_bytes(leaf), 0ULL + #c[3])
	check(c[1] .. " " .. c[3] .. " is_eq", rt.str_is_eq(leaf, c[3]), true)
	check(c[1] .. " " .. c[3] .. " as right operand", rt.str(rt.str_concat(("p"):rep(70), leaf)), ("p"):rep(70) .. c[3])
	check(c[1] .. " " .. c[3] .. " as left operand", rt.str(rt.str_concat(leaf, ("q"):rep(70))), c[3] .. ("q"):rep(70))
	check(c[1] .. " " .. c[3] .. " short concat", rt.str(rt.str_concat("ab", leaf)), "ab" .. c[3])
end
-- Seeded histories mixing leaves into appends to newest and older values.
for history = 1, 100 do
	local values, refs = { "" }, { "" }
	for step = 1, 80 do
		local i = rand(4) == 0 and rand(#values) + 1 or #values
		local right, right_ref
		if rand(2) == 0 then
			local v = rand(2000000) - 1000
			right, right_ref = rt.i64_to_str(v), ("%d"):format(v)
		else
			right = pieces[rand(#pieces) + 1]
			right_ref = right
		end
		local left, left_ref = values[i], refs[i]
		if rand(10) == 0 then left, left_ref = rt.u64_to_str(step), ("%d"):format(step) end
		values[#values + 1] = rt.str_concat(left, right)
		refs[#refs + 1] = left_ref .. right_ref
		check(("leaf history %d step %d length"):format(history, step), rt.str_count_utf8_bytes(values[#values]), 0ULL + #refs[#refs])
	end
	for k = 1, #values do check(("leaf history %d value %d"):format(history, k), rt.str(values[k]), refs[k]) end
end
-- Appending a number leaf counts its decimal length arithmetically. Reading
-- the buffer's length back after the write and storing it in the new view
-- miscompiled under allocation sinking (str_build printed 102 instead of
-- 488890 in about a third of JIT runs, never with -O-sink). Checked against
-- %d formatting at every power-of-ten boundary, both signs.
-- Numbers whose Lua tostring differs from %d formatting must still read as
-- their decimal digits through every view-aware op.
for _, v in ipairs({ 1e15, -(2 ^ 53 - 1), 2 ^ 53, 123456789 }) do
	local s, want = rt.i64_to_str(v), ("%d"):format(v)
	check(("number Str %s formats"):format(want), rt.str(s), want)
	check(("number Str %s length"):format(want), rt.str_count_utf8_bytes(s), 0ULL + #want)
	check(("number Str %s is_eq"):format(want), rt.str_is_eq(s, want), true)
	check(("number Str %s is_eq reversed"):format(want), rt.str_is_eq(want, s), true)
	check(("number Str %s as left operand"):format(want), rt.str(rt.str_concat(s, ("q"):rep(70))), want .. ("q"):rep(70))
	check(("number Str %s concat with itself"):format(want), rt.str(rt.str_concat(s, s)), want .. want)
	check(("number Str %s short concat"):format(want), rt.str(rt.str_concat("x", s)), "x" .. want)
end
local decimal_cases = { 0, 2 ^ 53 - 1, 2 ^ 53, -(2 ^ 53) }
for k = 1, 18 do
	local p = 10 ^ k
	for _, v in ipairs({ p - 1, p, p + 1 }) do
		decimal_cases[#decimal_cases + 1] = v
		decimal_cases[#decimal_cases + 1] = -v
	end
end
for _, v in ipairs(decimal_cases) do
	check(("decimal length of %d"):format(v), rt.int_decimal_len(v), #("%d"):format(v))
end

if failures > 0 then
	io.stderr:write(("runtime_strings: %d failures\n"):format(failures))
	os.exit(1)
end
print("runtime_strings: all passed")
