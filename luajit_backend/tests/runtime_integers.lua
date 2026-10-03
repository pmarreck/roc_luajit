-- Runtime integer semantics, checked against references computed another way:
-- exhaustively over every U8/I8 operand pair, and with boundary vectors for
-- the wider types. Run with: luajit luajit_backend/tests/runtime_integers.lua
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

-- Returns (value, crashed_message) for a checked op.
local function attempt(f, a, b)
	local ok, result = pcall(f, a, b, "overflow!")
	if ok then return result, nil end
	return nil, result.message
end

local widths = {
	u8 = { lo = 0, hi = 255 },
	i8 = { lo = -128, hi = 127 },
}

-- Reference: exact integer result, then range test / modular reduction by
-- repeated addition of the modulus (not the `%` the runtime uses).
local function reduce(v, lo, hi)
	local m = hi - lo + 1
	while v > hi do v = v - m end
	while v < lo do v = v + m end
	return v
end

for name, w in pairs(widths) do
	for a = w.lo, w.hi do
		for b = w.lo, w.hi do
			for op, exact in pairs({ add = a + b, sub = a - b, mul = a * b }) do
				local label = ("%s_%s(%d,%d)"):format(op, name, a, b)
				check("wrap " .. label, rt[op .. "_wrap_" .. name](a, b), reduce(exact, w.lo, w.hi))
				local v, crashed = attempt(rt[op .. "_checked_" .. name], a, b)
				if exact < w.lo or exact > w.hi then
					check("checked crash " .. label, crashed, "overflow!")
				else
					check("checked " .. label, v, exact)
				end
			end
		end
	end
end

-- U32 wrap multiplication needs exact low bits beyond 2^53.
check("mul_wrap_u32 max*max", rt.mul_wrap_u32(4294967295, 4294967295), 1)
check("mul_wrap_u32 2^31*2", rt.mul_wrap_u32(2147483648, 2), 0)
check("mul_wrap_i32 min*-1", rt.mul_wrap_i32(-2147483648, -1), -2147483648)
check("add_wrap_i32 max+1", rt.add_wrap_i32(2147483647, 1), -2147483648)
local _, c = attempt(rt.mul_checked_u32, 65536, 65536)
check("mul_checked_u32 overflow", c, "overflow!")

-- 64-bit boundary vectors.
local I64_MAX, I64_MIN = 9223372036854775807LL, -9223372036854775807LL - 1LL
local U64_MAX = 18446744073709551615ULL
local cases64 = {
	{ "add_checked_i64", I64_MAX, 1LL, nil },
	{ "add_checked_i64", I64_MAX, -1LL, I64_MAX - 1LL },
	{ "add_checked_i64", I64_MIN, -1LL, nil },
	{ "sub_checked_i64", I64_MIN, 1LL, nil },
	{ "sub_checked_i64", 0LL, I64_MIN, nil },
	{ "sub_checked_i64", -1LL, I64_MIN, I64_MAX },
	{ "mul_checked_i64", I64_MIN, -1LL, nil },
	{ "mul_checked_i64", -1LL, I64_MIN, nil },
	{ "mul_checked_i64", 3037000499LL, 3037000499LL, 9223372030926249001LL },
	{ "mul_checked_i64", 3037000500LL, 3037000500LL, nil },
	{ "mul_checked_i64", -4611686018427387904LL, 2LL, I64_MIN },
	{ "add_checked_u64", U64_MAX, 1ULL, nil },
	{ "add_checked_u64", U64_MAX - 1ULL, 1ULL, U64_MAX },
	{ "sub_checked_u64", 0ULL, 1ULL, nil },
	{ "mul_checked_u64", 4294967296ULL, 4294967296ULL, nil },
	{ "mul_checked_u64", 4294967295ULL, 4294967297ULL, U64_MAX },
}
for _, case in ipairs(cases64) do
	local f, a, b, want = case[1], case[2], case[3], case[4]
	local v, crashed = attempt(rt[f], a, b)
	local label = ("%s(%s,%s)"):format(f, tostring(a), tostring(b))
	if want == nil then check(label, crashed, "overflow!") else check(label, v, want) end
end

check("i64_to_str min", rt.str(rt.i64_to_str(I64_MIN)), "-9223372036854775808")
check("u64_to_str max", rt.str(rt.u64_to_str(U64_MAX)), "18446744073709551615")
check("i8_to_str", rt.str(rt.i8_to_str(-128)), "-128")

-- Wide-integer crashes must be the runtime's crash value, so run_main reports
-- them as Roc crashes (exit 3) rather than Lua errors (exit 1).
local ZERO128 = rt.W128(0, 0, 0, 0, 0, 0, 0, 0)
local ok, err = pcall(rt.dec_div, rt.W128(1, 0, 0, 0, 0, 0, 0, 0), ZERO128)
check("dec_div by zero crashes", ok, false)
local marker = pcall(rt.crash, "probe") or select(2, pcall(rt.crash, "probe"))
check("wide crash uses runtime crash value", getmetatable(err) ~= nil and getmetatable(err) == getmetatable(marker), true)
check("wide crash message", err.message, "Decimal division by 0!")
check("dec_to_str via rt", rt.dec_to_str(rt.W128(0, 0xa764, 0xb6b3, 0x0de0, 0, 0, 0, 0)), "1.0")


-- String patterns follow LIR.strMatchStep: a delimiter is checked only at the
-- first occurrence of its first byte after the cursor.
-- Wide fast paths against the general routines they shortcut, over boundary
-- values and seeded random operands (reproducible).
do
	local I128 = dofile(src .. "int128.lua")(W)
	local ONE = W.from_decimal("1000000000000000000", 8)
	local function same(a, b)
		if #a ~= #b then return false end
		for i = 1, #a do if a[i] ~= b[i] then return false end end
		return true
	end
	local function show(a) return a and table.concat(a, ",") or "nil" end
	local function random_limbs(n, used)
		local r = W.zero(n)
		for i = 1, used do r[i] = math.random(0, 65535) end
		return r
	end
	math.randomseed(20261001)

	local samples = { 0, 1, -1, 65535, 65536, -65536, 2 ^ 32, 2 ^ 53 - 1, -(2 ^ 53 - 1), 999999999999999999 }
	for _ = 1, 10000 do
		local bits = math.random(0, 53)
		local v = math.floor(math.random() * 2 ^ bits)
		if v >= 2 ^ 53 then v = 2 ^ 53 - 1 end
		samples[#samples + 1] = math.random() < 0.5 and -v or v
	end
	for _, v in ipairs(samples) do
		local want = W.resize(W.mul_full(W.from_small(math.abs(v), 8), ONE), 8)
		if v < 0 then want = W.sub(W.zero(8), want) end
		local got = I128.dec_from_small_int(v)
		check(("dec_from_small_int %.0f"):format(v), same(got, want) and "ok" or show(got), "ok")
		check(("cvt_int_dec %.0f"):format(v), same(rt.cvt_int_dec(v, "i64"), want) and "ok" or "differs", "ok")
	end

	for k = 1, 10000 do
		local a = random_limbs(16, math.random(1, 16))
		local b = random_limbs(8, math.random(1, 8))
		if W.is_zero(b) then b[1] = 1 end
		local q, r = W.divmod(a, b)
		local q_only, none = W.divmod(a, b, true)
		check(("divmod quotient_only #%d"):format(k), same(q_only, q) and none == nil and "ok" or show(q_only), "ok")
		check(("divmod remainder kept #%d"):format(k), r ~= nil, true)

		local d = math.random(1, 2 ^ 36 - 1)
		local sq, srem = W.divmod_small(a, d)
		local in_place = W.copy(a)
		local irem = W.div_small_in_place(in_place, d)
		check(("div_small_in_place #%d"):format(k), same(in_place, sq) and irem == srem and "ok" or show(in_place), "ok")

		local x = random_limbs(8, math.random(0, 8))
		check(("neg #%d"):format(k), same(W.neg(x), W.sub(W.zero(8), x)) and "ok" or show(W.neg(x)), "ok")
	end
end

-- W.divmod against its defining property, with no other division involved:
-- q * b + r == a and r < b, built from mul_full, add and cmp. Boundary
-- operands, then seeded random ones whose divisor length and top limb vary
-- (every normalization shift, single-limb divisors, a < b, a == b).
do
	local function limbs(n, values)
		local r = W.zero(n)
		for i, v in ipairs(values) do r[i] = v end
		return r
	end
	local function show(a) return table.concat(a, ",") end
	local function check_divmod(label, a, b)
		local q, r = W.divmod(a, b)
		local q_only = W.divmod(a, b, true)
		local n = #a
		local width = n + #b
		local back = W.add(W.resize(W.mul_full(q, b), width), W.resize(r, width))
		local ok = W.cmp(back, W.resize(a, width)) == 0
			and W.cmp(W.resize(r, n), W.resize(b, n)) < 0
			and W.cmp(q_only, q) == 0
		check(("divmod property %s a=%s b=%s"):format(label, show(a), show(b)), ok and "ok" or ("q=" .. show(q) .. " r=" .. show(r)), "ok")
	end
	local MAX = 65535
	local boundary = {
		{ limbs(16, { 7 }), limbs(8, { 1 }) },
		{ limbs(16, { MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX }), limbs(8, { MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX }) },
		{ limbs(16, { MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX, MAX }), limbs(8, { 1 }) },
		{ limbs(16, { 0 }), limbs(8, { 3 }) },
		{ limbs(16, { 5, 9 }), limbs(8, { 5, 9 }) },
		{ limbs(16, { 4, 9 }), limbs(8, { 5, 9 }) },
		{ limbs(16, { 0, 0, 0, 0, 1 }), limbs(8, { MAX, MAX, MAX, MAX }) },
		{ limbs(16, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32768 }), limbs(8, { 1, 0, 0, 1 }) },
		{ limbs(16, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32768 }), limbs(8, { 0, 0, 0, 32768 }) },
		-- These take the add-back step in base 2^26 (found by search).
		{ limbs(16, { 65535, 1, 32768, 65535, 65535, 32767, 32767, 0, 0, 32768, 65535, 1 }), limbs(8, { 0, 65535, 32768, 32768, 1, 0, 0, 32768 }) },
		{ limbs(16, { 32767, 32767, 1, 32767, 32768, 0, 65535, 65535, 0, 1, 1, 32768 }), limbs(8, { 1, 1, 65535, 32767, 32768, 32768 }) },
		{ limbs(16, { 0, 1, 0, 1, 65535, 0, 32767, 32768, 0, 1, 32767 }), limbs(8, { 65535, 65535, 0, 1, 1 }) },
	}
	for i, case in ipairs(boundary) do check_divmod("boundary " .. i, case[1], case[2]) end
	math.randomseed(20261002)
	for k = 1, 20000 do
		local a = W.zero(16)
		for i = 1, math.random(1, 16) do a[i] = math.random(0, MAX) end
		local b = W.zero(8)
		local m = math.random(1, 8)
		for i = 1, m do b[i] = math.random(0, MAX) end
		-- The divisor's top limb from 1 up to a full 16 bits: every shift.
		b[m] = math.random(1, 2 ^ math.random(1, 16) - 1)
		check_divmod("random " .. k, a, b)
	end
end

local function match(s, prefix, delims, tail)
	if not rt.str_match(s, prefix, delims, tail) then return "miss" end
	local parts = {}
	for i = 1, #delims do parts[i] = rt.cap[i] end
	return table.concat(parts, "|")
end
check("str_match exact empty step", match("key=val", "", { "=", "" }, false), "miss")
check("str_match exact", match("key=val;", "", { "=", ";" }, false), "key|val")
check("str_match prefix", match("GET /a", "GET ", { "" }, true), "/a")
check("str_match prefix miss", match("PUT /a", "GET ", { "" }, true), "miss")
check("str_match first-byte rule", match("x-y-=z", "", { "-=", "" }, true), "miss")
check("str_match later delimiter", match("x-=y-=z", "", { "-=", "-=", "" }, true), "x|y|z")
check("str_match exact end", match("a,b,", "", { ",", "," }, false), "a|b")
check("str_match exact end miss", match("a,b,c", "", { ",", "," }, false), "miss")
check("str_match tail end", match("a,b,c", "", { ",", "," }, true), "a|b")
check("str_match empty delimiter", match("abc", "a", { "", "c" }, false), "|b")

-- Bitwise and/or/xor on Lua-number integer types, against a bit-by-bit
-- reference in plain arithmetic (no `bit` library): every U8/I8 operand pair,
-- and boundary operands for the 16- and 32-bit types.
local bit_types = {
	u8 = { bits = 8, signed = false }, i8 = { bits = 8, signed = true },
	u16 = { bits = 16, signed = false }, i16 = { bits = 16, signed = true },
	u32 = { bits = 32, signed = false }, i32 = { bits = 32, signed = true },
}
local function ref_bitwise(op, a, b, t)
	local m = 2 ^ t.bits
	local x, y = a % m, b % m
	local r, place = 0, 1
	for _ = 1, t.bits do
		local p, q = x % 2, y % 2
		local o
		if op == "band" then o = p * q elseif op == "bor" then o = (p + q > 0) and 1 or 0 else o = (p + q) % 2 end
		r = r + o * place
		x, y, place = (x - p) / 2, (y - q) / 2, place * 2
	end
	if t.signed and r >= m / 2 then r = r - m end
	return r
end
-- 64-bit to narrower conversions keep the low bits, from either
-- representation of a U64/I64 (a Lua number below 2^53, else cdata).
-- Reference: two's-complement modular reduction in uint64_t arithmetic.
local ffi = require("ffi")
local wide_operands = {
	0, 1, 255, 256, 65535, 65536, 2 ^ 31 - 1, 2 ^ 31, 2 ^ 32 - 1, 2 ^ 32, 2 ^ 32 + 7, 2 ^ 53 - 1,
	-1, -2, -255, -256, -2 ^ 31, -2 ^ 31 - 1, -2 ^ 32, -2 ^ 53 + 1, -0.0,
	ffi.new("uint64_t", 2 ^ 53) + 1, 0xffffffffffffffffULL, 0x8000000000000000ULL, 0x123456789abcdef0ULL,
	ffi.new("int64_t", -2 ^ 53) - 1, -0x7fffffffffffffffLL - 1,
}
local function ref_low_bits(v, t)
	local u = ffi.cast("uint64_t", ffi.cast("int64_t", v))
	local r = tonumber(u % ffi.cast("uint64_t", 2 ^ t.bits))
	if t.signed and r >= 2 ^ (t.bits - 1) then r = r - 2 ^ t.bits end
	return r
end
for _, src in ipairs({ "u64", "i64" }) do
	for name, t in pairs(bit_types) do
		local f = rt["cvt_" .. src .. "_" .. name]
		for _, v in ipairs(wide_operands) do
			local is_neg = (type(v) == "number" and v < 0) or (ffi.istype("int64_t", v) and v < 0)
			if not (src == "u64" and is_neg) then
				check(("cvt_%s_%s(%s)"):format(src, name, tostring(v)), f(v), ref_low_bits(v, t))
			end
		end
	end
end

for name, t in pairs(bit_types) do
	local operands
	if t.bits == 8 then
		operands = {}
		local lo = t.signed and -128 or 0
		for v = lo, lo + 255 do operands[#operands + 1] = v end
	else
		local m = 2 ^ t.bits
		local lo = t.signed and -m / 2 or 0
		local hi = lo + m - 1
		operands = { lo, lo + 1, hi, hi - 1, 0, 1, -1, 0x55, 0xAA, m / 4, m / 4 - 1, m / 2 - 1, 12345 }
		local kept = {}
		for _, v in ipairs(operands) do if v >= lo and v <= hi then kept[#kept + 1] = v end end
		operands = kept
	end
	for _, op in ipairs({ "band", "bor", "bxor" }) do
		local f = rt[op .. "_" .. name]
		for _, a in ipairs(operands) do
			for _, b in ipairs(operands) do
				check(("%s_%s(%d, %d)"):format(op, name, a, b), f(a, b), ref_bitwise(op, a, b, t))
			end
		end
	end
end

if failures == 0 then
	print("runtime_integers: all passed")
	os.exit(0)
end
print(("runtime_integers: %d failed"):format(failures))
os.exit(1)
