-- roc_luajit runtime, embedded at the top of every emitted program.
-- Representations (ARCHITECTURE.md §5): U8..I32 are Lua numbers, U64/I64 are
-- Lua numbers when -2^53 < v < 2^53 and uint64_t/int64_t cdata otherwise
-- (see "64-bit integers"), Bool is a Lua boolean, Str is an immutable Lua
-- string, zero-sized values are the ZST sentinel.
local ffi = require("ffi")
local bit = require("bit")
-- Exact 16-bit-limb integers (wide.lua), the I128/U128/Dec layer built on
-- them (int128.lua), the List constructor (list.lua), the float module
-- (float.lua), fluxsort (sort.lua), the numeric parsers (numparse.lua) and
-- the float transcendentals (fmath.lua), SIMD (simd.lua) and SHA-256/BLAKE3
-- (crypto.lua),
-- passed in by the emitted prelude or a test harness.
local W, I128, LIST, FLOAT, SORT, NUMPARSE, FMATH, SIMD, CRYPTO = ...

local M = {}

M.ZST = setmetatable({}, { __tostring = function() return "ZST" end })

-- Crashes -------------------------------------------------------------------

local crash_mt = {}

function M.crash(message)
	error(setmetatable({ roc_crash = true, message = message }, crash_mt), 0)
end
I128.set_crash(M.crash)

-- An entry that resolves to `module[name]` on its first call and replaces
-- itself. Sort, numparse, fmath, SIMD and crypto may arrive as tables built
-- on first read (the emitted prelude compiles them on demand), so the runtime
-- reads their fields only when a program calls them.
local function on_first_call(key, module, name)
	M[key] = function(...)
		local f = module[name]
		M[key] = f
		return f(...)
	end
end

-- Lists (list.lua): a port of src/builtins/list.zig.
M.L = LIST(M.crash, M.ZST, SORT)
-- Flat list storage: rt.LF[k] is list.lua's module for elements of k leaves.
M.LF = setmetatable({}, { __index = function(t, k)
	local m = M.L.flat(k)
	t[k] = m
	return m
end })
-- Host boundary for flat list storage: hosts read and build lists with one
-- value per element (tables for records and tags), so the emitter's per-layout
-- converters call these. `conv` converts each element further (nested lists),
-- or is nil.
function M.list_to_tables(l, k, mat, conv)
	local n, F = l[3], M.LF[k]
	local a = { [0] = 1 }
	for i = 0, n - 1 do
		local e = mat(F.get_unsafe(l, i))
		if conv then e = conv(e) end
		a[i + 1] = e
	end
	return (M.L.literal(1, a, n))
end
function M.list_from_tables(l, k, unp, conv)
	local n = l[3]
	local a = require("table.new")(n * k, 0)
	for i = 0, n - 1 do
		local e = M.L.get_unsafe(l, i)
		if conv then e = conv(e) end
		local leaves, base = { unp(e) }, i * k
		for j = 1, k do a[base + j] = leaves[j] end
	end
	return (M.LF[k].literal(1, a, n))
end
function M.list_map_values(l, conv)
	local n = l[3]
	local a = { [0] = 1 }
	for i = 0, n - 1 do a[i + 1] = conv(M.L.get_unsafe(l, i)) end
	return (M.L.literal(1, a, n))
end
-- A static list of flat elements: the emitter writes each element as its
-- table (static data is built once, at load); unp gives back its k leaves.
function M.flat_static(k, unp, n, slice, elems, w)
	local a = require("table.new")(n * k, 0)
	for i = 1, n do
		local base = (i - 1) * k
		local leaves = { unp(elems[i]) }
		for j = 1, k do a[base + j] = leaves[j] end
	end
	return (M.LF[k].static(n, slice, a, w))
end
-- 128-bit integer SIMD (simd.lua, a port of builtins/simd.zig).
M.V = SIMD(W, M.L)
-- SHA-256 and BLAKE3 (crypto.lua), named after their LowLevel ops.
local C = CRYPTO(M.L, M.crash)
for _, name in ipairs({ "sha256_hash_bytes", "sha256_hasher_empty", "sha256_hasher_write", "sha256_hasher_finish", "blake3_hash_bytes", "blake3_hasher_empty", "blake3_hasher_write", "blake3_hasher_finish" }) do
	on_first_call("crypto_" .. name, C, name)
end

-- Floats (float.lua): binary32 rounding, bit access and Roc's float formatting.
local F = FLOAT(W)
M.F = F
for _, name in ipairs({ "f32", "f64_bits", "f64_from_bits", "f32_bits", "f32_from_bits", "f64_to_str", "f32_to_str" }) do
	M[name] = F[name]
end

local function on_error(err)
	if getmetatable(err) == crash_mt then return err end
	return debug.traceback(tostring(err), 2)
end

-- Run the root procedure. A Str result goes to stdout and exit status 0; a
-- Roc crash writes its message to stderr with status 3; any other Lua error
-- (an emitter or runtime bug) exits 1 with a traceback.
function M.run_main(main)
	local ok, result = xpcall(main, on_error)
	if ok then
		-- The root callee's R.h wrapper already made a Str result a Lua string.
		if type(result) ~= "string" then
			io.stderr:write("roc_luajit: main returned " .. type(result) .. ", expected Str\n")
			os.exit(1)
		end
		io.stdout:write(result)
		io.stdout:flush()
		os.exit(0)
	elseif getmetatable(result) == crash_mt then
		io.stderr:write(result.message)
		io.stderr:flush()
		os.exit(3)
	else
		io.stderr:write(tostring(result), "\n")
		os.exit(1)
	end
end

-- Reference counting ----------------------------------------------------------
-- The emitter forwards every LIR RC statement here. Str is an immutable Lua
-- string in M1: it has no storage to count and no Str operation in the
-- supported subset checks uniqueness, so its helpers have nothing to update.
-- A counted Str representation replaces this before in-place Str ops (M5).

function M.incref_str(_, _) end
function M.decref_str(_) end
function M.free_str(_) end

-- Numeric conversions -----------------------------------------------------------
-- Every integer conversion goes through a 9-limb (144-bit) value: sign-
-- extended for signed sources, zero-extended for unsigned ones, so U128 values
-- above 2^127 stay distinct from negative I128 values. A value fits a
-- destination exactly when converting there and back reproduces it.
-- Semantics follow the interpreter's intToNumeric / decToNumeric
-- (src/base/numeric_conversion.zig names src, dst and mode per op).

local CANON = 9
local int_kinds = {
	u8 = { bits = 8, signed = false }, i8 = { bits = 8, signed = true },
	u16 = { bits = 16, signed = false }, i16 = { bits = 16, signed = true },
	u32 = { bits = 32, signed = false }, i32 = { bits = 32, signed = true },
	u64 = { bits = 64, signed = false }, i64 = { bits = 64, signed = true },
	u128 = { bits = 128, signed = false }, i128 = { bits = 128, signed = true },
}
for _, k in pairs(int_kinds) do
	if k.bits <= 64 then
		k.range, k.half = 2 ^ k.bits, 2 ^ (k.bits - 1)
		k.mask = bit.rshift(0xffffffffffffffffULL, 64 - k.bits)
	end
end

local function extend(limbs, from, signed)
	-- limbs[1..from] valid; fill the rest with the sign (or zero).
	local fill = (signed and limbs[from] >= 32768) and 65535 or 0
	for i = from + 1, CANON do limbs[i] = fill end
	return limbs
end

local function to_canon(kind, v)
	local k = int_kinds[kind]
	if k.bits <= 32 then
		local u = v % 2 ^ k.bits -- two's complement bits as a non-negative number
		local limbs = { u % 65536, math.floor(u / 65536) }
		if k.bits <= 16 then limbs[2] = nil end
		local n = k.bits <= 16 and 1 or 2
		if k.bits == 8 and k.signed then
			limbs[1] = v < 0 and v + 65536 or v -- sign-extend the byte to 16 bits
		end
		return (extend(limbs, n, k.signed))
	elseif k.bits == 64 then
		local u = ffi.cast("uint64_t", v)
		local limbs = {}
		for i = 1, 4 do
			limbs[i] = tonumber(bit.band(bit.rshift(u, 16 * (i - 1)), 0xffff))
		end
		return (extend(limbs, 4, k.signed))
	end
	local limbs = {}
	for i = 1, 8 do limbs[i] = v[i] end
	return (extend(limbs, 8, k.signed))
end

local function from_canon(kind, c)
	local k = int_kinds[kind]
	if k.bits <= 32 then
		local u = c[1] + (k.bits > 16 and c[2] * 65536 or 0)
		u = u % 2 ^ k.bits
		if k.signed and u >= 2 ^ (k.bits - 1) then u = u - 2 ^ k.bits end
		return u
	elseif k.bits == 64 then
		local u = 0ULL
		for i = 4, 1, -1 do u = bit.bor(bit.lshift(u, 16), c[i]) end
		if k.signed then return (M.norm_i64(ffi.cast("int64_t", u))) end
		return (M.norm_u64(u))
	end
	local w = {}
	for i = 1, 8 do w[i] = c[i] end
	return w
end

local function canon_equal(a, b)
	for i = 1, CANON do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local zero_of = {
	u8 = 0, i8 = 0, u16 = 0, i16 = 0, u32 = 0, i32 = 0,
	u64 = 0, i64 = 0,
}

-- Integer to integer: exact (always fits), wrap (modulo the range), or try
-- (`{ success, value }`, success a U8).
-- Conversions between kinds of at most 64 bits skip the canonical form:
-- narrowing keeps the low bits (reinterpreted as signed when the
-- destination is), widening sign- or zero-extends by the source kind.
local function narrow(v, k, d)
	if d.bits <= 32 then
		local u
		-- A Lua number is exact below 2^53, so `%` keeps its low bits without
		-- a 64-bit cdata mask; only cdata (|v| >= 2^53) needs the mask.
		if type(v) == "number" then
			u = v % d.range
		else
			u = tonumber(bit.band(v, d.mask))
		end
		if d.signed and u >= d.half then u = u - d.range end
		return u
	end
	-- To 64 bits. Every source value below 2^53 in magnitude stays a number
	-- when the destination can hold it; anything else goes through the bits.
	if type(v) == "number" and (d.signed or v >= 0) then return v end
	if d.signed then return (M.norm_i64(ffi.cast("int64_t", v))) end
	return (M.norm_u64(ffi.cast("uint64_t", v)))
end
-- Integer.from_le_bytes (num_from_le_bytes_unchecked): the `width` bytes of
-- List(U8) `l` from 0-based `index`, little-endian, as integer kind `kind`
-- (two's complement for signed kinds). The caller checked the bounds.
-- Built as canonical 16-bit limbs, which from_canon reads for every kind.
for kind, k in pairs(int_kinds) do
	local width = k.bits / 8
	M["from_le_bytes_" .. kind] = function(l, index)
		local base = tonumber(index)
		local c = {}
		for j = 1, CANON do
			local lo = 2 * j - 2
			local b0 = lo < width and M.L.get_unsafe(l, base + lo) or 0
			local b1 = lo + 1 < width and M.L.get_unsafe(l, base + lo + 1) or 0
			c[j] = b0 + 256 * b1
		end
		return (from_canon(kind, c))
	end
end
function M.cvt_int(v, src, dst)
	local k, d = int_kinds[src], int_kinds[dst]
	if k.bits <= 64 and d.bits <= 64 then return (narrow(v, k, d)) end
	return (from_canon(dst, to_canon(src, v)))
end
-- Per-pair conversions between kinds of at most 64 bits (rt.cvt_u64_u32 and
-- so on), which the emitter calls for every lossy pair: each closes over its
-- two kinds, so a trace through it is specialized to that pair.
for src, k in pairs(int_kinds) do
	for dst, d in pairs(int_kinds) do
		if k.bits <= 64 and d.bits <= 64 then
			M["cvt_" .. src .. "_" .. dst] = function(v) return (narrow(v, k, d)) end
		end
	end
end
function M.cvt_int_try(v, src, dst)
	local k, d = int_kinds[src], int_kinds[dst]
	if k.bits <= 64 and d.bits <= 64 then
		-- Exact when converting back reproduces the value with the same sign.
		local out = narrow(v, k, d)
		if narrow(out, d, k) == v and (out < 0) == (v < 0) then return { 1, out } end
		return { 0, zero_of[dst] }
	end
	local c = to_canon(src, v)
	local out = from_canon(dst, c)
	if canon_equal(to_canon(dst, out), c) then return { 1, out } end
	return { 0, zero_of[dst] or W.zero(8) }
end

local DEC_ONE = W.from_decimal("1000000000000000000", 8)

-- Integer to Dec: exact multiplies by 10^18 with wrapping; try_unsafe uses
-- RocDec.fromWholeInt (checked) after rejecting U128 values above I128 max.
function M.cvt_int_dec(v, src)
	-- Integer kinds up to 64 bits arrive as Lua numbers below 2^53 in
	-- magnitude, or as int64/uint64 cdata (mixed representation).
	if type(v) == "number" then return (I128.dec_from_small_int(v)) end
	return (I128.mul_wrap(from_canon("i128", to_canon(src, v)), DEC_ONE))
end
function M.cvt_int_dec_try(v, src)
	local c = to_canon(src, v)
	local as_i128 = from_canon("i128", c)
	if not canon_equal(to_canon("i128", as_i128), c) then return { 0, W.zero(8) } end
	local ok, r = pcall(I128.mul_checked_i128, as_i128, DEC_ONE, "")
	if ok then return { 1, r } end
	return { 0, W.zero(8) }
end

-- Dec to integer: the whole part (truncated toward zero), then wrapped (trunc)
-- or range-checked (try_unsafe), as builtins/dec.zig toIntWrap / toIntTry.
local function dec_whole(d)
	return (I128.div_trunc_i128(d, DEC_ONE))
end
function M.cvt_dec_int(d, dst) return (from_canon(dst, to_canon("i128", dec_whole(d)))) end
function M.cvt_dec_int_try(d, dst)
	local c = to_canon("i128", dec_whole(d))
	local out = from_canon(dst, c)
	if canon_equal(to_canon(dst, out), c) then return { 1, out } end
	return { 0, zero_of[dst] or W.zero(8) }
end

-- Conversions involving floats (intToFloat, floatToInt, floatNarrow, decToFloat
-- and their try forms), exact through float.lua.
local function sign_magnitude(c)
	local negative = c[CANON] >= 32768
	if negative then c = W.neg(c) end
	return negative, c
end

function M.cvt_int_float(v, src, is_f32)
	local negative, magnitude = sign_magnitude(to_canon(src, v))
	return (F.int_to_float(negative, magnitude, is_f32))
end

function M.cvt_float_int(x, is_f32, dst)
	local bits = F.float_to_int_bits(x, is_f32, int_kinds[dst].bits)
	return (from_canon(dst, extend(W.resize(bits, CANON), 8, false)))
end

-- floatToIntTry: finite, truncated, and within the target's range.
function M.cvt_float_int_try(x, is_f32, dst)
	if x ~= x or x == math.huge or x == -math.huge then return { 0, zero_of[dst] or W.zero(8) } end
	local t = x >= 0 and math.floor(x) or math.ceil(x)
	local k = int_kinds[dst]
	local fits
	if k.signed then
		fits = t >= -2 ^ (k.bits - 1) and t < 2 ^ (k.bits - 1)
	else
		fits = t >= 0 and t < 2 ^ k.bits
	end
	if not fits then return { 0, zero_of[dst] or W.zero(8) } end
	return { 1, M.cvt_float_int(t, is_f32, dst) }
end

local F32_MAX = 3.4028234663852886e38
function M.cvt_f64_f32(x) return (F.f32(x)) end
function M.cvt_f64_f32_try(x)
	if x == x and x <= F32_MAX and x >= -F32_MAX then return { 1, F.f32(x) } end
	return { 0, 0 }
end

function M.cvt_dec_float(d, is_f32)
	local negative, magnitude = sign_magnitude(to_canon("i128", d))
	if is_f32 then return (F.dec_to_f32(negative, magnitude)) end
	return (F.dec_to_f64(negative, magnitude))
end
function M.cvt_dec_f32_try(d) return { 1, M.cvt_dec_float(d, true) } end

-- Float arithmetic beyond the operators the emitter writes inline (floatBinOp
-- and the unary float ops). F32 results are rounded through rt.f32: for
-- + - * / and sqrt, rounding the exact double result again to binary32 equals
-- the single correctly rounded binary32 result (53 >= 2 * 24 + 2).
local f32 = F.f32
M.f64_to_bits, M.f32_to_bits = F.f64_bits, F.f32_bits
M.NEG_ZERO = -(0.0)
for _, kind in ipairs({ "f64", "f32" }) do
	local round = kind == "f32" and f32 or function(x) return x end
	M["div_trunc_" .. kind] = function(a, b)
		local q = round(a / b)
		if q >= 0 then return (math.floor(q)) end
		return (math.ceil(q))
	end
	-- @rem on floats: fmod (exact, sign of the dividend), for rem and mod.
	M["rem_" .. kind] = math.fmod
	M["mod_" .. kind] = math.fmod
	M["neg_wrap_" .. kind] = function(a) return -a end
	M["abs_wrap_" .. kind] = math.abs
	M["abs_diff_" .. kind] = function(a, b) return (math.abs(round(a - b))) end
	M["floor_" .. kind] = math.floor
	M["ceil_" .. kind] = math.ceil
	M["sqrt_" .. kind] = function(a) return (round(math.sqrt(a))) end
end

-- Strings ------------------------------------------------------------------------
-- A Str is a Lua string (UTF-8 bytes), a view: the first `n` bytes of an
-- append-only string.buffer `b`, an integer-valued Lua number (integer
-- to_str: the value itself, formatted with %d when read), or a leaf
-- `{ v, f }` holding an int64/uint64 cdata and its formatter. Numbers exist so
-- that a number concatenated onto a string is formatted straight into the
-- buffer and never becomes an interned Lua string; interning millions of
-- short-lived number strings made LuaJIT's string table the dominant,
-- super-linear cost of str_build (ARCHITECTURE.md). A plain number costs no
-- allocation, so its cost does not depend on LuaJIT sinking a table. Views
-- and leaves share STR_VIEW. Hosts never see a number or a table: the
-- emitter converts every Str crossing to a host (R.h<layout>) with M.str.
-- Concatenation makes views, so repeated
-- appends cost the appended bytes only (native Roc appends in place to a
-- unique string; Lua strings are immutable and `..` copies both sides).
-- A view's bytes never change, because its buffer only grows: appending to
-- the buffer's newest value (`#b == n`) extends it in place, and appending to
-- an older one copies that prefix to a new buffer. Only the operations below
-- that say so accept views; the emitter passes every other Str operand
-- through `M.str`, which materializes a view once and caches the string.
-- Semantics follow src/builtins/str.zig; ops that return lists build them
-- through M.L so their capacities match the builtins (Str is 24 bytes wide as
-- a list element).

local STR_WIDTH = 24
local byte, sub, find = string.byte, string.sub, string.find
local strbuf = require("string.buffer")
local STR_VIEW = {}
-- Shorter results stay plain strings: copying a few bytes is cheaper than a
-- buffer and a view.
local STR_VIEW_MIN_BYTES = 64

local function str(s)
	local t = type(s)
	if t == "string" then return s end
	if t == "number" then return (string.format("%d", s)) end
	local cached = s.s
	if cached then return cached end
	if s.b then cached = ffi.string(s.b:ref(), s.n) else cached = s.f(s.v) end
	s.s = cached
	return cached
end
M.str = str

-- Exact powers of ten as doubles (10^0..10^22 are all representable).
local POW10 = {}
for k = 1, 22 do POW10[k] = 10 ^ k end
-- Decimal length of an integer-valued Lua number as %d prints it, by exact
-- power-of-ten comparisons: appending a number leaf adds this to the view's
-- byte count instead of reading the buffer's length back after the write
-- (ARCHITECTURE.md §10, number leaves).
local function int_decimal_len(v)
	local d = 1
	if v < 0 then d, v = 2, -v end
	local k = 1
	while k <= 22 and v >= POW10[k] do k = k + 1 end
	return d + k - 1
end
M.int_decimal_len = int_decimal_len

-- Views and numbers accepted.
function M.str_concat(a, b)
	if type(a) == "number" or (type(a) ~= "string" and a.b == nil) then a = str(a) end
	local bv = type(b) == "number" and b or nil
	if not bv then b = str(b) end
	if type(a) == "string" then
		if bv then b = str(b) end
		local n = #a + #b
		if n < STR_VIEW_MIN_BYTES then return a .. b end
		local buf = strbuf.new(2 * n)
		buf:put(a, b)
		return (setmetatable({ b = buf, n = n }, STR_VIEW))
	end
	local buf, n = a.b, a.n
	local added = bv and int_decimal_len(bv) or #b
	if #buf ~= n then
		local copy = strbuf.new(2 * (n + added))
		copy:putcdata(buf:ref(), n)
		buf = copy
	end
	if bv then buf:putf("%d", bv) else buf:put(b) end
	return (setmetatable({ b = buf, n = n + added }, STR_VIEW))
end
function M.str_is_eq(a, b) return str(a) == str(b) end
function M.str_count_utf8_bytes(s)
	local t = type(s)
	if t == "string" then return #s end
	if t == "number" then return (int_decimal_len(s)) end
	if s.b then return s.n end
	return #str(s)
end

-- An int64/uint64 cdata's to_str result: a leaf formatted on first use.
local function int_leaf(v, f) return (setmetatable({ v = v, f = f }, STR_VIEW)) end
M.int_leaf = int_leaf

-- Replace every view inside a value with its string (hosts read Str fields
-- as Lua strings); returns the value, itself materialized if a view.
function M.str_get_utf8_byte_unsafe(s, i) return byte(s, tonumber(i) + 1) end
function M.str_substring_unsafe(s, start, len)
	start = tonumber(start)
	return (sub(s, start + 1, start + tonumber(len)))
end
function M.str_contains(h, n) return find(h, n, 1, true) ~= nil end
function M.str_starts_with(s, p) return sub(s, 1, #p) == p end
function M.str_ends_with(s, p) return #p <= #s and sub(s, #s - #p + 1) == p end
function M.str_drop_prefix(s, p)
	if sub(s, 1, #p) ~= p then return s end
	return (sub(s, #p + 1))
end
function M.str_drop_suffix(s, p)
	if not (#p <= #s and sub(s, #s - #p + 1) == p) then return s end
	return (sub(s, 1, #s - #p))
end

-- Roc's Str.inspect quoting: escape backslash and double quote only.
function M.str_inspect(s)
	return '"' .. (string.gsub(s, '[\\"]', '\\%0')) .. '"'
end

-- isWhitespace (Unicode White_Space subset used by Str.trim).
local function is_whitespace(cp)
	return (cp >= 0x9 and cp <= 0xD) or cp == 0x20 or cp == 0x85 or cp == 0xA0 or cp == 0x1680
		or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x200E or cp == 0x200F or cp == 0x2028
		or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000
end

-- Decode the codepoint starting at byte i (1-based) of valid UTF-8; returns
-- codepoint and its length.
local function decode_at(s, i)
	local b0 = byte(s, i)
	if b0 < 0x80 then return b0, 1 end
	if b0 < 0xE0 then return bit.bor(bit.lshift(bit.band(b0, 0x1F), 6), bit.band(byte(s, i + 1), 0x3F)), 2 end
	if b0 < 0xF0 then
		return bit.bor(bit.lshift(bit.band(b0, 0x0F), 12), bit.lshift(bit.band(byte(s, i + 1), 0x3F), 6), bit.band(byte(s, i + 2), 0x3F)), 3
	end
	return bit.bor(bit.lshift(bit.band(b0, 0x07), 18), bit.lshift(bit.band(byte(s, i + 1), 0x3F), 12),
		bit.lshift(bit.band(byte(s, i + 2), 0x3F), 6), bit.band(byte(s, i + 3), 0x3F)), 4
end

local function leading_ws(s)
	local i, n = 1, #s
	while i <= n do
		local cp, len = decode_at(s, i)
		if not is_whitespace(cp) then break end
		i = i + len
	end
	return i - 1
end

local function trailing_ws(s)
	local j = #s
	while j >= 1 do
		local start = j
		while start > 1 and bit.band(byte(s, start), 0xC0) == 0x80 do start = start - 1 end
		local cp = decode_at(s, start)
		if not is_whitespace(cp) then break end
		j = start - 1
	end
	return #s - j
end

function M.str_trim_start(s) return (sub(s, leading_ws(s) + 1)) end
function M.str_trim_end(s) return (sub(s, 1, #s - trailing_ws(s))) end
function M.str_trim(s)
	local lead = leading_ws(s)
	if lead == #s then return "" end
	return (sub(s, lead + 1, #s - trailing_ws(s)))
end

function M.str_with_ascii_lowercased(s) return (string.gsub(s, "%u", string.lower)) end
function M.str_with_ascii_uppercased(s) return (string.gsub(s, "%l", string.upper)) end
function M.str_caseless_ascii_equals(a, b)
	return #a == #b and string.lower(a) == string.lower(b)
end

function M.str_repeat(s, count)
	if count == 0ULL or #s == 0 then return "" end
	if tonumber(count) * #s >= 2 ^ 64 then
		M.crash("Str.repeat result length overflowed")
	end
	return (string.rep(s, tonumber(count)))
end

-- Little-endian byte k of a uint64 word.
local function word_byte(word, k)
	return (tonumber(bit.band(bit.rshift(word, 8 * k), 0xff)))
end
local function lower_ascii(b)
	if b >= 65 and b <= 90 then return b + 32 end
	return b
end

function M.str_is_eq_static_small(s, len, w0, w1, w2)
	len = tonumber(len)
	if len > 24 or #s ~= len then return false end
	local words = { w0, w1, w2 }
	for i = 0, len - 1 do
		if byte(s, i + 1) ~= word_byte(words[math.floor(i / 8) + 1], i % 8) then return false end
	end
	return true
end
function M.str_static_small_word_eq(s, offset, active, word)
	offset, active = tonumber(offset), tonumber(active)
	if active > 8 or offset > #s or active > #s - offset then return false end
	for k = 0, active - 1 do
		if byte(s, offset + k + 1) ~= word_byte(word, k) then return false end
	end
	return true
end
function M.str_static_small_word_caseless_eq(s, offset, active, word)
	offset, active = tonumber(offset), tonumber(active)
	if active > 8 or offset > #s or active > #s - offset then return false end
	for k = 0, active - 1 do
		if lower_ascii(byte(s, offset + k + 1)) ~= lower_ascii(word_byte(word, k)) then return false end
	end
	return true
end

-- Records in their semantic (alphabetical) field order.
function M.str_split_first(s, d)
	if #d == 0 then return { s, "", true } end
	local i = find(s, d, 1, true)
	if not i then return { "", "", false } end
	return { sub(s, i + #d), sub(s, 1, i - 1), true }
end
function M.str_split_last(s, d)
	if #d == 0 then return { "", s, true } end
	local last
	local from = 1
	while true do
		local i = find(s, d, from, true)
		if not i then break end
		last = i
		from = i + 1
	end
	if not last then return { "", "", false } end
	return { sub(s, last + #d), sub(s, 1, last - 1), true }
end
function M.str_drop_prefix_caseless_ascii(s, p)
	if #p > #s or string.lower(sub(s, 1, #p)) ~= string.lower(p) then return { "", false } end
	return { sub(s, #p + 1), true }
end

-- strSplitOn: segments in a list allocated by list_allocate(count, 24).
function M.str_split_on(s, d)
	local parts = {}
	if #d == 0 then
		parts[1] = s
	else
		local from = 1
		while true do
			local i = find(s, d, from, true)
			if not i then break end
			parts[#parts + 1] = sub(s, from, i - 1)
			from = i + #d
		end
		parts[#parts + 1] = sub(s, from)
	end
	local l = M.L.allocate(#parts, STR_WIDTH)
	for i = 1, #parts do l[1][i] = parts[i] end
	return l
end

-- strJoinWith over a List(Str); releases the list as the builtin does.
function M.str_join_with(l, sep)
	local parts = {}
	for i = 0, l[3] - 1 do parts[i + 1] = str(M.L.get_unsafe(l, i)) end
	M.L.decref(l, nil)
	return (table.concat(parts, sep))
end

-- String interpolation patterns (LIR strMatchPrefixMatches, strMatchStep,
-- strMatchDelimiter, strMatchEndMatches). On a match `M.cap[i]` holds step i's
-- captured bytes; the emitter reads the bound ones immediately. A delimiter is
-- tried only at the first occurrence of its first byte, exactly as LIR does.
local cap = {}
M.cap = cap
function M.str_match(s, prefix, delims, tail)
	local n, p = #s, #prefix
	if p > n or sub(s, 1, p) ~= prefix then return false end
	local cursor = p
	local steps = #delims
	for i = 1, steps do
		local d = delims[i]
		local dn = #d
		if cursor > n then return false end
		local found
		if tail and i == steps and dn == 0 then
			cap[i] = sub(s, cursor + 1, n)
			cursor = n
		else
			if dn == 0 then
				found = cursor
			else
				if dn > n - cursor then return false end
				local candidate = find(s, sub(d, 1, 1), cursor + 1, true)
				if not candidate then return false end
				candidate = candidate - 1
				if dn > n - candidate or sub(s, candidate + 1, candidate + dn) ~= d then return false end
				found = candidate
			end
			cap[i] = sub(s, cursor + 1, found)
			cursor = found + dn
		end
	end
	if tail then return cursor <= n end
	return cursor == n
end

-- strToBytes: a fresh exact-capacity List(U8). Heap strings' capacity is not
-- modelled (ARCHITECTURE.md decision log).
function M.str_to_utf8(s)
	local n = #s
	if n == 0 then return (M.L.empty()) end
	local a = {}
	for i = 1, n do a[i] = byte(s, i) end
	return (M.L.literal(1, a, n))
end

function M.str_with_capacity() return "" end
function M.str_reserve(s) return s end
function M.str_release_excess_capacity(s) return s end

-- Boxes ------------------------------------------------------------------------
-- A box is a counted cell { rc = count, v = value }. Counts follow the LIR RC
-- statements exactly (ARCHITECTURE.md section 4, policy C); uniqueness checks read rc.
-- A host may give a box a `drop` function, called once with the payload when
-- the box is released for the last time: the counterpart of a native host's
-- roc_dealloc finalizer for resources such as files and child processes.

function M.box_new(v) return { rc = 1, v = v } end

-- utils.increfDataPtr / decref on a box; rc 0 is static data, never counted.
function M.box_incref(b, n)
	if b.rc ~= 0 then b.rc = b.rc + n end
end
local function box_dropped(b)
	local drop = b.drop
	if drop then
		b.drop = nil
		drop(b.v)
	end
end
function M.box_decref(b, dec)
	local c = b.rc
	if c == 0 then return end
	if c == 1 then
		if dec then dec(b.v) end
		box_dropped(b)
	end
	b.rc = c - 1
end
function M.box_free(b, dec)
	if dec then dec(b.v) end
	box_dropped(b)
end

-- evalBoxPrepareUpdate: a uniquely owned box (or one ARC proved unique, or a
-- zero-sized payload) is updated in place; otherwise copy the payload into a
-- fresh box, retain the payload's children, and release the input box.
function M.box_prepare_update(b, in_place, zero_sized, inc_payload, dec_box)
	if zero_sized or in_place or b.rc == 1 then return b end
	local fresh = { rc = 1, v = b.v }
	if inc_payload then inc_payload(b.v, 1) end
	if dec_box then dec_box(b) end
	return fresh
end

-- Host dbg, as the echo platform prints it: "[dbg] <message>\n" on stderr.
-- Native hosts write unbuffered, so stdout is flushed first to keep the two
-- streams in program order.
-- Hosts with another format replace `M.on_dbg`.
function M.on_dbg(message) io.stderr:write("[dbg] ", message, "\n") end
function M.dbg(message)
	io.stdout:flush()
	M.on_dbg(message)
end

-- A failed inline expect: reported as the default and echo hosts do
-- ("Expect failed: <message>"); execution continues, and a host turns a later
-- successful exit into status 1 (`M.inline_expect_failed`).
M.inline_expect_failed = false
-- Hosts with another policy replace `M.on_expect_failed`.
function M.on_expect_failed(message) io.stderr:write("Expect failed: ", message, "\n") end
function M.expect_failed(message)
	M.inline_expect_failed = true
	io.stdout:flush()
	M.on_expect_failed(message)
end

-- Platform mode (LuaEmitter `Input.entrypoints`) ---------------------------------
-- The hosted function the platform's LuaJIT host provides for `symbol`.
function M.hosted(host, symbol)
	local f = host[symbol]
	if type(f) ~= "function" then
		error("roc_luajit: the platform's LuaJIT host does not provide hosted function " .. symbol, 0)
	end
	return f
end

-- Run a platform entrypoint. Returns true and its result; false and the
-- message of a Roc crash; or false, nil and "stack_overflow" when Lua or C
-- stack space ran out (native Roc overflows its stack there). Any other Lua
-- error is a backend bug and exits 1 with a traceback.
function M.call_entry(entry, ...)
	local ok, result = xpcall(entry, on_error, ...)
	if ok then return true, result end
	if getmetatable(result) == crash_mt then return false, result.message end
	if type(result) == "string" and result:match("stack overflow") then return false, nil, "stack_overflow" end
	io.stdout:flush()
	io.stderr:write("roc_luajit internal error: ", tostring(result), "\n")
	os.exit(1)
end

-- A List(Str) built as roc_args builds the process arguments: exact capacity,
-- invalid UTF-8 replaced by U+FFFD.
function M.host_str_list(strings)
	local a = {}
	for i = 1, #strings do a[i] = M.str_from_utf8_lossy(M.str_to_utf8(strings[i])) end
	if #a == 0 then return (M.L.empty()) end
	return (M.L.literal(24, a, #a))
end

function M.runtime_error()
	error("roc_luajit: reached a LIR runtime_error statement", 0)
end

-- Erased callables: { rc, proc, cap, drop }. `drop` releases the captures
-- (the on_drop RC helper) when the last reference goes. Packing may reuse a
-- uniquely owned callable, as evalPackedErasedFn does. Like builtins/
-- erased_callable.zig, incref/decref/free accept a null (nil) callable, which
-- an erased call passes as the reuse slot when it does not reuse the closure.
function M.erased_pack(proc, cap, drop, reuse, reuse_unique)
	if reuse then
		if reuse_unique or reuse.rc == 1 then
			if reuse.drop then reuse.drop(reuse.cap) end
			reuse.proc, reuse.cap, reuse.drop = proc, cap, drop
			return reuse
		end
		M.erased_decref(reuse)
	end
	return { rc = 1, proc = proc, cap = cap, drop = drop }
end
function M.erased_incref(e, n)
	if e and e.rc ~= 0 then e.rc = e.rc + n end
end
function M.erased_decref(e)
	if not e then return end
	local c = e.rc
	if c == 0 then return end
	if c == 1 and e.drop then e.drop(e.cap) end
	e.rc = c - 1
end
function M.erased_free(e)
	if e and e.drop then e.drop(e.cap) end
end

-- Numeric parsing (numparse.lua). `{t}_from_str` returns the Result
-- { 1, value } or { 0, err }, where `err` is the zero-filled Err payload the
-- emitter supplies (the interpreter writes nothing there). Prefix parses return the record { err, rest, value } that the
-- interpreter's writePrefixParse fills: err 0, 1 (no number token) or 2 (token
-- out of range); rest is the unparsed remainder on success and empty
-- otherwise; value is zero on error. `kind` is "int", "dec" or "float"; `t`
-- names the result type ("u8".."i128", "dec", "f32", "f64").
local NP = NUMPARSE(W, F)
local PREFIX_NOT_A_NUMBER, PREFIX_OUT_OF_RANGE = 1, 2
local prefix_len = {
	int = function(s) return (NP.int_prefix_len(s)) end,
	dec = function(s) return (NP.dec_prefix_len(s)) end,
	float = function(s) return (NP.float_prefix_len(s)) end,
}

local function parsed_value(kind, t, token)
	if kind == "float" then return (NP.float_token(token, t == "f32")) end
	local negative, magnitude
	if kind == "dec" then
		negative, magnitude = NP.dec_token(token)
	else
		negative, magnitude = NP.int_token(t, token)
	end
	if negative == nil then return nil end
	local c = W.resize(magnitude, CANON)
	if negative then c = W.neg(c) end
	return (from_canon(kind == "dec" and "i128" or t, c))
end

local function parse_zero(t)
	if t == "f32" or t == "f64" then return 0 end
	return zero_of[t] or W.zero(8)
end

function M.num_from_str(s, kind, t, err)
	if #s == 0 or prefix_len[kind](s) ~= #s then return { 0, err } end
	local v = parsed_value(kind, t, s)
	if v == nil then return { 0, err } end
	return { 1, v }
end

-- The bytes of a List(U8) as a Lua string.
local function list_bytes(l)
	local a, o, parts = l[1], l[2], {}
	for i = 1, l[3] do parts[i] = string.char(a[o + i]) end
	return (table.concat(parts))
end
-- For hosts: a List(U8)'s bytes as a Lua string (str_to_utf8 is the inverse).
M.list_bytes = list_bytes

-- `{t}_from_str_prefix` (Str source) and `{t}_from_utf8_prefix` (List(U8)
-- source, whose rest is listFromUtf8PrefixRest: a retained borrowed sublist).
function M.num_from_prefix(src, kind, t, is_list)
	local s = is_list and list_bytes(src) or src
	local empty = is_list and M.L.empty() or ""
	local consumed = prefix_len[kind](s)
	if consumed == 0 then return { PREFIX_NOT_A_NUMBER, empty, parse_zero(t) } end
	local v = parsed_value(kind, t, s:sub(1, consumed))
	if v == nil then return { PREFIX_OUT_OF_RANGE, empty, parse_zero(t) } end
	local rest
	if not is_list then
		rest = s:sub(consumed + 1)
	elseif consumed == src[3] then
		rest = M.L.empty()
	else
		M.L.incref(src, 1, false)
		rest = M.L.sublist_borrowed(src, consumed, src[3] - consumed, false)
	end
	return { 0, rest, v }
end

-- Str.from_utf8 / from_utf8_lossy (builtins/str.zig fromUtf8, errorToProblem,
-- numberOfNextCodepointBytes, Utf8Iterator.nextLossy). Problem codes are
-- Utf8ByteProblem's, alphabetical like Roc's tags.
local UTF8_TOO_LARGE, UTF8_SURROGATE, UTF8_EXPECTED_CONTINUATION = 0, 1, 2
local UTF8_INVALID_START, UTF8_OVERLONG, UTF8_UNEXPECTED_END = 3, 4, 5

-- std.unicode.utf8ByteSequenceLength.
local function utf8_seq_len(b)
	if b < 0x80 then return 1 end
	if b >= 0xC0 and b <= 0xDF then return 2 end
	if b >= 0xE0 and b <= 0xEF then return 3 end
	if b >= 0xF0 and b <= 0xF7 then return 4 end
	return nil
end

-- std.unicode.utf8Decode of s[i .. i+n-1]: the codepoint, or nil and the
-- problem, checking in utf8Decode2/3/4's order.
local function utf8_decode(s, i, n)
	local b0 = string.byte(s, i)
	if n == 1 then return b0 end
	local value = b0 % (n == 2 and 32 or n == 3 and 16 or 8)
	for k = 1, n - 1 do
		local b = string.byte(s, i + k)
		if b < 0x80 or b >= 0xC0 then return nil, UTF8_EXPECTED_CONTINUATION end
		value = value * 64 + b % 64
	end
	if n == 2 then
		if value < 0x80 then return nil, UTF8_OVERLONG end
	elseif n == 3 then
		if value < 0x800 then return nil, UTF8_OVERLONG end
		if value >= 0xD800 and value <= 0xDFFF then return nil, UTF8_SURROGATE end
	else
		if value < 0x10000 then return nil, UTF8_OVERLONG end
		if value > 0x10FFFF then return nil, UTF8_TOO_LARGE end
	end
	return value
end

-- `ok(s)` and `err(index, problem)` build the Result in the layout the
-- emitter resolved (the interpreter's str_from_utf8 layout discovery).
function M.str_from_utf8(l, ok, err)
	local s = list_bytes(l)
	local len, i = #s, 1
	while i <= len do
		local n = utf8_seq_len(string.byte(s, i))
		if n == nil then return err(i - 1, UTF8_INVALID_START) end
		if i + n - 1 > len then return err(i - 1, UTF8_UNEXPECTED_END) end
		local cp, problem = utf8_decode(s, i, n)
		if cp == nil then return err(i - 1, problem) end
		i = i + n
	end
	return ok(s)
end

local REPLACEMENT = "\239\191\189" -- U+FFFD

function M.str_from_utf8_lossy(l)
	local s = list_bytes(l)
	local len, i, out = #s, 1, {}
	while i <= len do
		local b = string.byte(s, i)
		local n = utf8_seq_len(b)
		if n == nil then
			-- Invalid start byte: one replacement for the run of invalid
			-- start bytes (skipAdjacentInvalidStartBytes).
			i = i + 1
			while i <= len do
				local x = string.byte(s, i)
				if x < 0x80 or utf8_seq_len(x) ~= nil then break end
				i = i + 1
			end
			out[#out + 1] = REPLACEMENT
		else
			local bad = false
			for k = 1, n - 1 do
				if i + k > len then
					-- Unexpected end.
					i = i + k
					bad = true
					break
				end
				local x = string.byte(s, i + k)
				if x < 0x80 or x >= 0xC0 then
					-- Expected a continuation byte.
					i = i + k
					bad = true
					break
				end
			end
			if bad then
				out[#out + 1] = REPLACEMENT
			else
				out[#out + 1] = utf8_decode(s, i, n) and s:sub(i, i + n - 1) or REPLACEMENT
				i = i + n
			end
		end
	end
	return (table.concat(out))
end

-- Num.compare (the interpreter's evalCompare / cmpOrder): the
-- [Before, Same, After] discriminant, After 0, Before 1, Same 2; a NaN operand
-- is neither equal nor less, so it orders After.
function M.order(a, b)
	if a == b then return 2 end
	if a < b then return 1 end
	return 0
end
-- 128-bit and Dec operands, from their three-way comparison.
function M.order_cmp(c)
	if c == 0 then return 2 end
	if c < 0 then return 1 end
	return 0
end

-- Dict/Set hashing (builtins/hash.zig). A hasher state is a U64; each write
-- is wyhash(seed, domain byte .. le64(byte length) .. bytes), which is what
-- hasherFeed's streaming Wyhash computes.
local hash_band, hash_bor, hash_bxor = bit.band, bit.bor, bit.bxor
local hash_shl, hash_shr = bit.lshift, bit.rshift
local MASK32 = 0xffffffffULL
local P0, P1, P2, P3, P4 = 0xa0761d6478bd642fULL, 0xe7037ed1a0b428dbULL, 0x8ebc6af09c88c6e3ULL,
	0x589965cc75374cc3ULL, 0x1d8e4e27c47d124fULL

-- mum: the 128-bit product of two U64s, high half xor low half.
local function mum(a, b)
	local a_lo, a_hi = hash_band(a, MASK32), hash_shr(a, 32)
	local b_lo, b_hi = hash_band(b, MASK32), hash_shr(b, 32)
	local ll, lh, hl, hh = a_lo * b_lo, a_lo * b_hi, a_hi * b_lo, a_hi * b_hi
	local mid = hash_shr(ll, 32) + hash_band(lh, MASK32) + hash_band(hl, MASK32)
	local lo = hash_bor(hash_band(ll, MASK32), hash_shl(mid, 32))
	local hi = hh + hash_shr(lh, 32) + hash_shr(hl, 32) + hash_shr(mid, 32)
	return (hash_bxor(hi, lo))
end
local function mix0(a, b, seed) return (mum(hash_bxor(a, seed, P0), hash_bxor(b, seed, P1))) end
local function mix1(a, b, seed) return (mum(hash_bxor(a, seed, P2), hash_bxor(b, seed, P3))) end

-- Little-endian reads of k bytes at 1-based position p.
local function rd(s, p, k)
	local v = 0ULL
	for i = k - 1, 0, -1 do v = hash_bor(hash_shl(v, 8), string.byte(s, p + i)) end
	return v
end
local function rd_swapped(s, p) return (hash_bor(hash_shl(rd(s, p, 4), 32), rd(s, p + 4, 4))) end
-- WyhashStateless.final's operand for k (1..7) trailing bytes at p.
local function tail(s, p, k)
	if k == 1 then return (rd(s, p, 1)) end
	if k == 2 then return (rd(s, p, 2)) end
	if k == 3 then return (hash_bor(hash_shl(rd(s, p, 2), 8), rd(s, p + 2, 1))) end
	if k == 4 then return (rd(s, p, 4)) end
	if k == 5 then return (hash_bor(hash_shl(rd(s, p, 4), 8), rd(s, p + 4, 1))) end
	if k == 6 then return (hash_bor(hash_shl(rd(s, p, 4), 16), rd(s, p + 4, 2))) end
	return (hash_bor(hash_shl(rd(s, p, 4), 24), hash_shl(rd(s, p + 4, 2), 8), rd(s, p + 6, 1)))
end

-- Wyhash.hash (WyhashStateless): 32-byte rounds, then the length-specific tail.
local function wyhash(seed, s)
	local len = #s
	local aligned = len - len % 32
	for off = 1, aligned, 32 do
		seed = hash_bxor(mix0(rd(s, off, 8), rd(s, off + 8, 8), seed), mix1(rd(s, off + 16, 8), rd(s, off + 24, 8), seed))
	end
	local p, r = aligned + 1, len - aligned
	if r == 0 then
		-- seed unchanged
	elseif r < 8 then
		seed = mix0(tail(s, p, r), P4, seed)
	elseif r == 8 then
		seed = mix0(rd_swapped(s, p), P4, seed)
	elseif r < 16 then
		seed = mix0(rd_swapped(s, p), tail(s, p + 8, r - 8), seed)
	elseif r == 16 then
		seed = mix0(rd_swapped(s, p), rd_swapped(s, p + 8), seed)
	else
		local head = mix0(rd_swapped(s, p), rd_swapped(s, p + 8), seed)
		if r < 24 then
			seed = hash_bxor(head, mix1(tail(s, p + 16, r - 16), P4, seed))
		elseif r == 24 then
			seed = hash_bxor(head, mix1(rd_swapped(s, p + 16), P4, seed))
		else
			seed = hash_bxor(head, mix1(rd_swapped(s, p + 16), tail(s, p + 24, r - 24), seed))
		end
	end
	return (mum(hash_bxor(seed, 0ULL + len), P4))
end
M.wyhash = wyhash

local function le_bytes(v, width)
	local out = {}
	for i = 1, width do
		out[i] = string.char(tonumber(hash_band(v, 0xff)))
		v = hash_shr(v, 8)
	end
	return (table.concat(out))
end

local function hasher_feed(seed, domain, bytes)
	return (wyhash(seed, string.char(domain) .. le_bytes(0ULL + #bytes, 8) .. bytes))
end

-- A fixed-width write in closed form: the message is domain || le64(width)
-- || the low `width` bytes of v (9 + width bytes, so wyhash takes its 9..16
-- or 17..23 byte tail), and each wyhash operand is read off v directly
-- instead of from an assembled string.
local function hasher_feed_int(seed, domain, v, width)
	local head = hash_shl(0ULL + domain + width * 256, 32)
	if width == 8 then
		local second = hash_bor(hash_shl(hash_band(v, 0xffffff), 40), hash_band(hash_shr(v, 24), MASK32))
		seed = hash_bxor(mix0(head, second, seed), mix1(hash_shr(v, 56), P4, seed))
	elseif width == 4 then
		seed = mix0(head, hash_bor(hash_shl(hash_band(v, 0xffffff), 16), hash_shr(v, 24)), seed)
	elseif width == 2 then
		seed = mix0(head, hash_bor(hash_shl(hash_band(v, 0xff), 16), hash_shr(v, 8)), seed)
	else
		seed = mix0(head, hash_shl(v, 8), seed)
	end
	return (mum(hash_bxor(seed, 9ULL + width), P4))
end

-- Fixed-width integers and Bool: the value's two's-complement bits, `width` bytes.
function M.hash_write_int(seed, domain, v, width)
	if type(v) == "boolean" then
		v = v and 1ULL or 0ULL
	elseif type(v) == "number" and width < 8 then
		v = 0ULL + v % 2 ^ (8 * width)
	else
		v = ffi.cast("uint64_t", v)
	end
	return (hasher_feed_int(seed, domain, v, width))
end
-- U128, I128 and Dec bits (8-limb tables), low word then high word.
function M.hash_write_wide(seed, domain, w)
	local parts = {}
	for i = 1, 8 do parts[i] = string.char(w[i] % 256, math.floor(w[i] / 256)) end
	return (hasher_feed(seed, domain, table.concat(parts)))
end
-- F32/F64: both zeros hash alike, and every NaN as the canonical NaN.
function M.hash_write_f32(seed, x)
	local bits = (x == 0) and 0ULL or (0ULL + F.f32_bits(x))
	return (hasher_feed_int(seed, 0x0c, bits, 4))
end
function M.hash_write_f64(seed, x)
	local bits = (x == 0) and 0ULL or F.f64_bits(x)
	return (hasher_feed_int(seed, 0x0d, bits, 8))
end
function M.hash_write_str(seed, s) return (hasher_feed(seed, 0x10, s)) end
function M.hash_write_bytes(seed, l) return (hasher_feed(seed, 0x0f, list_bytes(l))) end
-- hasher_feed(seed, 0xff, "") in closed form: the 9-byte message 0xff ||
-- le64(0) takes wyhash's 9..15-byte tail, whose operands are 0xff << 32
-- (bytes 1..8, read swapped) and 0 (byte 9).
local FINISH_HEAD = 0xff00000000ULL
function M.hash_finish(seed) return (mum(hash_bxor(mix0(FINISH_HEAD, 0ULL, seed), 9ULL), P4)) end
-- dictPseudoSeed is the address of a function with the top bit set, so native
-- Roc's value varies by process; any seed with that marker bit is faithful.
function M.dict_pseudo_seed() return 0x8000000000005eedULL end

-- Two-field records built by list_replace_unsafe: { list, value } in the
-- result layout's semantic field order.
function M.record_lv(l, v) return { l, v } end
function M.record_vl(l, v) return { v, l } end
-- The same from a flat list's replace, whose old element is its leaves.
function M.record_lv_flat(mat, l, ...) return { l, mat(...) } end
function M.record_vl_flat(mat, l, ...) return { mat(...), l } end

-- Small integers (Lua numbers) -------------------------------------------------

local small = {
	u8 = { lo = 0, hi = 255, bits = 8, signed = false },
	i8 = { lo = -128, hi = 127, bits = 8, signed = true },
	u16 = { lo = 0, hi = 65535, bits = 16, signed = false },
	i16 = { lo = -32768, hi = 32767, bits = 16, signed = true },
	u32 = { lo = 0, hi = 4294967295, bits = 32, signed = false },
	i32 = { lo = -2147483648, hi = 2147483647, bits = 32, signed = true },
}

local u64 = ffi.typeof("uint64_t")

-- Exact product of two integers below 2^32 in magnitude, reduced to the
-- type's width. Doubles lose low bits above 2^53, so multiply as uint64_t.
local function wrap_small(t, v)
	local m = 2 ^ t.bits
	v = v % m
	if t.signed and v > t.hi then v = v - m end
	return v
end

local function mul_small(t, a, b)
	local p = ffi.cast(u64, a % 2 ^ 32) * ffi.cast(u64, b % 2 ^ 32)
	return (tonumber(p % ffi.cast(u64, 2 ^ t.bits)))
end

for name, t in pairs(small) do
	M["add_wrap_" .. name] = function(a, b) return (wrap_small(t, a + b)) end
	M["sub_wrap_" .. name] = function(a, b) return (wrap_small(t, a - b)) end
	M["mul_wrap_" .. name] = function(a, b) return (wrap_small(t, mul_small(t, a, b))) end
	M["add_checked_" .. name] = function(a, b, message)
		local r = a + b
		if r < t.lo or r > t.hi then M.crash(message) end
		return r
	end
	M["sub_checked_" .. name] = function(a, b, message)
		local r = a - b
		if r < t.lo or r > t.hi then M.crash(message) end
		return r
	end
	M["mul_checked_" .. name] = function(a, b, message)
		-- |a*b| < 2^64 here; a double product is exact enough to decide range.
		local r = a * b
		if r < t.lo or r > t.hi then M.crash(message) end
		return r
	end
	M[name .. "_to_str"] = function(v) return v end
end

-- Division family, negation and absolute value -----------------------------------
-- Semantics of the interpreter's intBinOp: unchecked forms return 0 for a zero
-- divisor; signed MIN / -1 returns the dividend, and its remainder and modulo
-- are 0. Checked forms crash with the messages the emitter passes in, which it
-- takes from lir/checked_arithmetic.zig.

-- Small integers: |a|, |b| < 2^32, so a / b as a double truncates to the exact
-- quotient (the gap to the next integer, at least 1/|b|, exceeds the rounding
-- error) and a - b * q is exact.
local function div_family(name, t, zero, is_zero, trunc_div, lt0, gt, sub)
	local min_div
	if t.signed then
		local min, minus_one = t.min, t.minus_one
		min_div = function(a, b) return a == min and b == minus_one end
	else
		min_div = function() return false end
	end
	local function rem(a, b) return (sub(a, b * trunc_div(a, b))) end
	local function mod(a, b)
		local r = rem(a, b)
		if r ~= zero and lt0(r) ~= lt0(b) then return r + b end
		return r
	end
	M["div_trunc_" .. name] = function(a, b)
		if is_zero(b) then return zero end
		if min_div(a, b) then return a end
		return (trunc_div(a, b))
	end
	M["div_trunc_checked_" .. name] = function(a, b, zero_message, overflow_message)
		if is_zero(b) then M.crash(zero_message) end
		if min_div(a, b) then M.crash(overflow_message) end
		return (trunc_div(a, b))
	end
	M["rem_" .. name] = function(a, b)
		if is_zero(b) or min_div(a, b) then return zero end
		return (rem(a, b))
	end
	M["mod_" .. name] = function(a, b)
		if is_zero(b) or min_div(a, b) then return zero end
		return (mod(a, b))
	end
	M["rem_checked_" .. name] = function(a, b, zero_message)
		if is_zero(b) then M.crash(zero_message) end
		if min_div(a, b) then return zero end
		return (rem(a, b))
	end
	M["mod_checked_" .. name] = function(a, b, zero_message)
		if is_zero(b) then M.crash(zero_message) end
		if min_div(a, b) then return zero end
		return (mod(a, b))
	end
	M["abs_diff_" .. name] = function(a, b)
		if gt(a, b) then return (sub(a, b)) end
		return (sub(b, a))
	end
end

local function trunc_small(a, b)
	local q = a / b
	if q >= 0 then return (math.floor(q)) end
	return (math.ceil(q))
end

for name, t in pairs(small) do
	local signed_t = { signed = t.signed, min = t.lo, minus_one = -1 }
	local function wrap(v) return (wrap_small(t, v)) end
	div_family(name, signed_t, 0, function(b) return b == 0 end, trunc_small,
		function(v) return v < 0 end, function(a, b) return a > b end,
		function(a, b) return (wrap(a - b)) end)
	-- Distance in the unsigned type of the same width; exact for Lua numbers.
	M["abs_diff_" .. name] = function(a, b)
		if a > b then return a - b end
		return b - a
	end
	M["neg_wrap_" .. name] = function(a) return (wrap(-a)) end
	M["neg_checked_" .. name] = function(a, message)
		local r = -a
		if r < t.lo or r > t.hi then M.crash(message) end
		return r
	end
	M["abs_wrap_" .. name] = function(a)
		if a < 0 then return (wrap(-a)) end
		return a
	end
	M["abs_checked_" .. name] = function(a, message)
		if a < 0 then
			if -a > t.hi then M.crash(message) end
			return -a
		end
		return a
	end
end

-- Bit operations -----------------------------------------------------------------
-- As the interpreter's shiftOp / bitwiseOp / bitCount: shift counts are taken
-- modulo the width; `shr` is arithmetic for signed types and `shr_zf` always
-- logical; counts return U8.

local function popcount_u(u, bits)
	local c = 0
	for _ = 1, bits do
		c = c + u % 2
		u = math.floor(u / 2)
	end
	return c
end

for name, t in pairs(small) do
	local bits = t.bits
	local function wrap(v) return (wrap_small(t, v)) end
	local function pattern(v) return v % 2 ^ bits end -- unsigned bit pattern
	M["shl_" .. name] = function(a, n) return (wrap(bit.lshift(bit.tobit(a), n % bits))) end
	M["shr_zf_" .. name] = function(a, n)
		local s = n % bits
		if s == 0 then return a end
		return (wrap(bit.rshift(bit.tobit(pattern(a)), s)))
	end
	if t.signed then
		M["shr_" .. name] = function(a, n) return (wrap(bit.arshift(bit.tobit(a), n % bits))) end
	else
		M["shr_" .. name] = M["shr_zf_" .. name]
	end
	M["bnot_" .. name] = function(a) return (wrap(bit.bnot(bit.tobit(a)))) end
	-- And/or/xor of two in-range values stay in range: zero-extended
	-- operands give a zero-extended result, sign-extended ones a
	-- sign-extended result, and bit's signed 32-bit result is already an
	-- I32. Only U32 needs its pattern back from the signed result.
	if name == "u32" then
		M.band_u32 = function(a, b) return bit.band(a, b) % 4294967296 end
		M.bor_u32 = function(a, b) return bit.bor(a, b) % 4294967296 end
		M.bxor_u32 = function(a, b) return bit.bxor(a, b) % 4294967296 end
	else
		M["band_" .. name] = function(a, b) return (bit.band(a, b)) end
		M["bor_" .. name] = function(a, b) return (bit.bor(a, b)) end
		M["bxor_" .. name] = function(a, b) return (bit.bxor(a, b)) end
	end
	M["popcount_" .. name] = function(a) return (popcount_u(pattern(a), bits)) end
	M["clz_" .. name] = function(a)
		local u, n = pattern(a), bits
		while u > 0 do
			u = math.floor(u / 2)
			n = n - 1
		end
		return n
	end
	M["ctz_" .. name] = function(a)
		local u = pattern(a)
		if u == 0 then return bits end
		local n = 0
		while u % 2 == 0 do
			u = u / 2
			n = n + 1
		end
		return n
	end
end

-- 64-bit integers -----------------------------------------------------------------
-- An I64 or U64 is a Lua number when -2^53 < v < 2^53 (U64: 0 <= v < 2^53),
-- or int64_t / uint64_t cdata, which can hold every value. Code may receive
-- either form for any value; results come back as numbers whenever they fit.
-- Numbers keep calls and list elements unboxed: LuaJIT boxes every 64-bit
-- cdata that crosses a call or a table store.
-- Each operation takes a number fast path only when all operands are numbers
-- and the double result r satisfies -2^53 < r < 2^53. Doubles round
-- monotonically and 2^53 is exact, so a true result of magnitude 2^53 or more
-- rounds to at least 2^53 and fails the test; otherwise the exact result is
-- recomputed in cdata. `+ 0` turns a -0 (from 0 * negative, ceil or fmod) into 0.

local i64t, u64t = ffi.typeof("int64_t"), ffi.typeof("uint64_t")
local SAFE = 2 ^ 53
local I64_MIN = -9223372036854775807LL - 1LL

local function I(v) return (ffi.cast(i64t, v)) end
local function U(v) return (ffi.cast(u64t, v)) end
-- An exact int64/uint64 result as a number when it fits.
local function norm_i(c)
	if c > -SAFE and c < SAFE then return (tonumber(c)) end
	return c
end
local function norm_u(c)
	if c < SAFE then return (tonumber(c)) end
	return c
end
M.norm_i64, M.norm_u64 = norm_i, norm_u

local function both_numbers(a, b) return type(a) == "number" and type(b) == "number" end

function M.add_wrap_i64(a, b)
	if both_numbers(a, b) then
		local r = a + b
		if r > -SAFE and r < SAFE then return r end
	end
	return (norm_i(I(a) + I(b)))
end
function M.sub_wrap_i64(a, b)
	if both_numbers(a, b) then
		local r = a - b
		if r > -SAFE and r < SAFE then return r end
	end
	return (norm_i(I(a) - I(b)))
end
function M.mul_wrap_i64(a, b)
	if both_numbers(a, b) then
		local r = a * b
		if r > -SAFE and r < SAFE then return r + 0 end
	end
	return (norm_i(I(a) * I(b)))
end
function M.add_wrap_u64(a, b)
	if both_numbers(a, b) then
		local r = a + b
		if r < SAFE then return r end
	end
	return (norm_u(U(a) + U(b)))
end
function M.sub_wrap_u64(a, b)
	if both_numbers(a, b) and a >= b then return a - b end
	return (norm_u(U(a) - U(b)))
end
function M.mul_wrap_u64(a, b)
	if both_numbers(a, b) then
		local r = a * b
		if r < SAFE then return r end
	end
	return (norm_u(U(a) * U(b)))
end

function M.add_checked_i64(a, b, message)
	if both_numbers(a, b) then
		local r = a + b
		if r > -SAFE and r < SAFE then return r end
	end
	local x, y = I(a), I(b)
	local r = x + y
	if bit.band(bit.bxor(x, r), bit.bxor(y, r)) < 0LL then M.crash(message) end
	return (norm_i(r))
end

function M.sub_checked_i64(a, b, message)
	if both_numbers(a, b) then
		local r = a - b
		if r > -SAFE and r < SAFE then return r end
	end
	local x, y = I(a), I(b)
	local r = x - y
	if bit.band(bit.bxor(x, y), bit.bxor(x, r)) < 0LL then M.crash(message) end
	return (norm_i(r))
end

function M.mul_checked_i64(a, b, message)
	if both_numbers(a, b) then
		local r = a * b
		if r > -SAFE and r < SAFE then return r + 0 end
	end
	local x, y = I(a), I(b)
	if x == 0LL or y == 0LL then return 0 end
	if x == -1LL then
		if y == I64_MIN then M.crash(message) end
		return (norm_i(-y))
	end
	if y == -1LL then
		if x == I64_MIN then M.crash(message) end
		return (norm_i(-x))
	end
	local r = x * y
	if r / y ~= x then M.crash(message) end
	return (norm_i(r))
end

function M.add_checked_u64(a, b, message)
	if both_numbers(a, b) then
		local r = a + b
		if r < SAFE then return r end
	end
	local x = U(a)
	local r = x + U(b)
	if r < x then M.crash(message) end
	return (norm_u(r))
end

function M.sub_checked_u64(a, b, message)
	if a < b then M.crash(message) end
	if both_numbers(a, b) then return a - b end
	return (norm_u(U(a) - U(b)))
end

function M.mul_checked_u64(a, b, message)
	if both_numbers(a, b) then
		local r = a * b
		if r < SAFE then return r end
	end
	local x, y = U(a), U(b)
	if x == 0ULL or y == 0ULL then return 0 end
	local r = x * y
	if r / y ~= x then M.crash(message) end
	return (norm_u(r))
end

-- Division family (the interpreter's intBinOp, as for the small integers
-- above): unchecked forms return 0 for a zero divisor; I64 MIN / -1 returns
-- the dividend, and its remainder and modulo are 0. Two numbers divide as
-- doubles: |a| < 2^53, so a / b truncates to the exact quotient (the gap to
-- the next integer, at least 1/|b|, exceeds half an ulp of the quotient) and
-- a - b * q is exact. Otherwise LuaJIT's int64/uint64 `/` truncates toward
-- zero and the remainder is derived from the quotient.
local function trunc_div_i(a, b)
	if both_numbers(a, b) then
		local q = a / b
		if q >= 0 then return (math.floor(q)) end
		return math.ceil(q) + 0
	end
	return (norm_i(I(a) / I(b)))
end
local function trunc_div_u(a, b)
	if both_numbers(a, b) then return (math.floor(a / b)) end
	return (norm_u(U(a) / U(b)))
end
local function rem_i(a, b)
	if both_numbers(a, b) then return a - b * trunc_div_i(a, b) + 0 end
	local x, y = I(a), I(b)
	return (norm_i(x - y * (x / y)))
end
local function rem_u(a, b)
	if both_numbers(a, b) then return a - b * math.floor(a / b) end
	local x, y = U(a), U(b)
	return (norm_u(x - y * (x / y)))
end
local function mod_i(a, b)
	local r = rem_i(a, b)
	if r ~= 0 and (r < 0) ~= (b < 0) then return (M.add_wrap_i64(r, b)) end
	return r
end
local function min_div_i(a, b) return a == I64_MIN and b == -1 end
local function never() return false end

for name, f in pairs({
	i64 = { div = trunc_div_i, rem = rem_i, mod = mod_i, min_div = min_div_i },
	u64 = { div = trunc_div_u, rem = rem_u, mod = rem_u, min_div = never },
}) do
	local div, rem, mod, min_div = f.div, f.rem, f.mod, f.min_div
	M["div_trunc_" .. name] = function(a, b)
		if b == 0 then return 0 end
		if min_div(a, b) then return a end
		return (div(a, b))
	end
	M["div_trunc_checked_" .. name] = function(a, b, zero_message, overflow_message)
		if b == 0 then M.crash(zero_message) end
		if min_div(a, b) then M.crash(overflow_message) end
		return (div(a, b))
	end
	M["rem_" .. name] = function(a, b)
		if b == 0 or min_div(a, b) then return 0 end
		return (rem(a, b))
	end
	M["mod_" .. name] = function(a, b)
		if b == 0 or min_div(a, b) then return 0 end
		return (mod(a, b))
	end
	M["rem_checked_" .. name] = function(a, b, zero_message)
		if b == 0 then M.crash(zero_message) end
		if min_div(a, b) then return 0 end
		return (rem(a, b))
	end
	M["mod_checked_" .. name] = function(a, b, zero_message)
		if b == 0 then M.crash(zero_message) end
		if min_div(a, b) then return 0 end
		return (mod(a, b))
	end
end

-- I64 abs_diff is a U64: the wrapped difference reinterpreted as unsigned.
function M.abs_diff_i64(a, b)
	if both_numbers(a, b) then
		local r = a - b
		if r > -SAFE and r < SAFE then return (math.abs(r)) end
	end
	local x, y = I(a), I(b)
	if x > y then return (norm_u(U(x - y))) end
	return (norm_u(U(y - x)))
end
function M.abs_diff_u64(a, b)
	if a > b then return (M.sub_wrap_u64(a, b)) end
	return (M.sub_wrap_u64(b, a))
end
function M.neg_wrap_i64(a)
	if type(a) == "number" then return 0 - a end
	return (norm_i(-I(a)))
end
function M.neg_wrap_u64(a)
	if a == 0 then return 0 end
	return (norm_u(0ULL - U(a)))
end
function M.neg_checked_i64(a, message)
	if a == I64_MIN then M.crash(message) end
	return (M.neg_wrap_i64(a))
end
function M.neg_checked_u64(a, message)
	if a ~= 0 then M.crash(message) end
	return 0
end
function M.abs_wrap_i64(a)
	if a < 0 then return (M.neg_wrap_i64(a)) end
	return a
end
function M.abs_wrap_u64(a) return a end
function M.abs_checked_i64(a, message)
	if a == I64_MIN then M.crash(message) end
	if a < 0 then return (M.neg_wrap_i64(a)) end
	return a
end
function M.abs_checked_u64(a) return a end

-- Bit operations on the two's-complement bits, as uint64 (`bit` on two Lua
-- numbers would work on 32 bits only).
for _, name in ipairs({ "i64", "u64" }) do
	local signed = name == "i64"
	local ct = signed and i64t or u64t
	local norm = signed and norm_i or norm_u
	M["shl_" .. name] = function(a, n) return (norm(ffi.cast(ct, bit.lshift(U(a), n % 64)))) end
	M["shr_zf_" .. name] = function(a, n) return (norm(ffi.cast(ct, bit.rshift(U(a), n % 64)))) end
	if signed then
		M["shr_" .. name] = function(a, n) return (norm_i(bit.arshift(I(a), n % 64))) end
	else
		M["shr_" .. name] = M["shr_zf_" .. name]
	end
	M["bnot_" .. name] = function(a) return (norm(ffi.cast(ct, bit.bnot(U(a))))) end
	M["band_" .. name] = function(a, b) return (norm(ffi.cast(ct, bit.band(U(a), U(b))))) end
	M["bor_" .. name] = function(a, b) return (norm(ffi.cast(ct, bit.bor(U(a), U(b))))) end
	M["bxor_" .. name] = function(a, b) return (norm(ffi.cast(ct, bit.bxor(U(a), U(b))))) end
	M["popcount_" .. name] = function(a)
		local x, c = U(a), 0
		while x ~= 0ULL do
			c = c + tonumber(bit.band(x, 1ULL))
			x = bit.rshift(x, 1)
		end
		return c
	end
	M["clz_" .. name] = function(a)
		local x, n = U(a), 64
		while x ~= 0ULL do
			x = bit.rshift(x, 1)
			n = n - 1
		end
		return n
	end
	M["ctz_" .. name] = function(a)
		local x = U(a)
		if x == 0ULL then return 64 end
		local n = 0
		while bit.band(x, 1ULL) == 0ULL do
			x = bit.rshift(x, 1)
			n = n + 1
		end
		return n
	end
end

-- 128-bit values: eight 16-bit limbs.
local function limbwise(f)
	return function(a, b)
		local r = {}
		for i = 1, 8 do r[i] = f(a[i], b[i]) end
		return r
	end
end
local function bnot128(a)
	local r = {}
	for i = 1, 8 do r[i] = 65535 - a[i] end
	return r
end
for _, name in ipairs({ "i128", "u128" }) do
	local signed = name == "i128"
	M["shl_" .. name] = function(a, n) return (W.shl(a, n % 128)) end
	M["shr_zf_" .. name] = function(a, n) return (W.shr(a, n % 128)) end
	if signed then
		M["shr_" .. name] = function(a, n)
			if a[8] >= 32768 then return (bnot128(W.shr(bnot128(a), n % 128))) end
			return (W.shr(a, n % 128))
		end
	else
		M["shr_" .. name] = M["shr_zf_" .. name]
	end
	M["bnot_" .. name] = bnot128
	M["band_" .. name] = limbwise(function(x, y) return (bit.band(x, y)) end)
	M["bor_" .. name] = limbwise(function(x, y) return (bit.bor(x, y)) end)
	M["bxor_" .. name] = limbwise(function(x, y) return (bit.bxor(x, y)) end)
	M["popcount_" .. name] = function(a)
		local c = 0
		for i = 1, 8 do c = c + popcount_u(a[i], 16) end
		return c
	end
	M["clz_" .. name] = function(a)
		for i = 8, 1, -1 do
			if a[i] ~= 0 then return (8 - i) * 16 + M.clz_u16(a[i]) end
		end
		return 128
	end
	M["ctz_" .. name] = function(a)
		for i = 1, 8 do
			if a[i] ~= 0 then return (i - 1) * 16 + M.ctz_u16(a[i]) end
		end
		return 128
	end
end

-- `*_overflows`: whether the checked operation would crash.
for _, name in ipairs({ "u8", "i8", "u16", "i16", "u32", "i32", "u64", "i64", "u128", "i128" }) do
	for _, op in ipairs({ "add", "sub", "mul" }) do
		local checked = op .. "_checked_" .. name
		M[op .. "_overflows_" .. name] = function(a, b)
			return not pcall(M[checked], a, b, "")
		end
	end
end

-- A number below 2^53 prints exactly with %d; tostring(int64 cdata) is
-- decimal plus an "LL"/"ULL" suffix.
local function format_i64(v)
	if type(v) == "number" then return (string.format("%d", v)) end
	return (string.gsub(tostring(v), "LL$", ""))
end
local function format_u64(v)
	if type(v) == "number" then return (string.format("%d", v)) end
	return (string.gsub(tostring(v), "ULL$", ""))
end
function M.i64_to_str(v)
	if type(v) == "number" then return v end
	return (int_leaf(v, format_i64))
end
function M.u64_to_str(v)
	if type(v) == "number" then return v end
	return (int_leaf(v, format_u64))
end

-- 128-bit integers and Dec (8-limb values; see int128.lua) ---------------------

-- Literal constructor: eight 16-bit limbs, least significant first.
M.W128 = function(...) return { ... } end

for _, kind in ipairs({ "i128", "u128" }) do
	M["add_wrap_" .. kind] = I128.add_wrap
	M["sub_wrap_" .. kind] = I128.sub_wrap
	M["mul_wrap_" .. kind] = I128.mul_wrap
	M["add_checked_" .. kind] = I128["add_checked_" .. kind]
	M["sub_checked_" .. kind] = I128["sub_checked_" .. kind]
	M["mul_checked_" .. kind] = I128["mul_checked_" .. kind]
	M["cmp_" .. kind] = I128["cmp_" .. kind]
	for _, op in ipairs({ "div_trunc", "div_trunc_checked", "rem", "rem_checked", "mod", "mod_checked", "abs_diff", "neg_wrap", "neg_checked", "abs_wrap", "abs_checked" }) do
		M[op .. "_" .. kind] = I128[op .. "_" .. kind]
	end
	M[kind .. "_to_str"] = I128[kind .. "_to_str"]
end

-- Dec is an I128 scaled by 10^18: addition and subtraction are I128 ops.
M.add_wrap_dec = I128.add_wrap
M.sub_wrap_dec = I128.sub_wrap
M.add_checked_dec = I128.add_checked_i128
M.sub_checked_dec = I128.sub_checked_i128
M.cmp_dec = I128.cmp_i128
M.dec_mul = I128.dec_mul
M.dec_div = I128.dec_div
M.dec_to_str = I128.dec_to_str
for _, op in ipairs({ "dec_div_trunc", "dec_rem", "dec_mod", "neg_wrap_dec", "abs_wrap_dec", "abs_checked_dec", "abs_diff_dec" }) do
	M[op] = I128[op]
end
-- Dec transcendentals (int128.lua ports of dec.zig), named `<stem>_dec`.
for _, stem in ipairs({ "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "pow", "sqrt", "log" }) do
	M[stem .. "_dec"] = I128["dec_" .. stem]
end
-- F32/F64 transcendentals (fmath.lua ports of float_math), named `<stem>_f32`/`<stem>_f64`.
local FM = FMATH(F)
for _, stem in ipairs({ "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "pow", "log" }) do
	on_first_call(stem .. "_f32", FM, stem .. "_f32")
	on_first_call(stem .. "_f64", FM, stem .. "_f64")
end

return M
