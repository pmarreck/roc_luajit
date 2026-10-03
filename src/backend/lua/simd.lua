-- Roc's 128-bit integer SIMD for the roc_luajit runtime: a lane-for-lane port
-- of src/builtins/simd.zig, the target-independent oracle the interpreter uses.
--
-- A vector is an immutable `roc_v128` FFI union; every operation returns a new
-- one. Lane kinds are descriptors: `w` lane bits, `n` lane count, `s` signed,
-- `f` the natural field (what Roc's lane scalar is), `uf`/`sf` the unsigned
-- and signed fields of that width. Lanes up to 32 bits are Lua numbers and
-- 64-bit lanes are uint64/int64 cdata, matching the scalar representations.
-- Every value stored is already in its field's range, so no store relies on
-- FFI truncation of an out-of-range Lua number.
return function(W, L)
	local ffi = require("ffi")
	local bit = require("bit")
	local floor = math.floor
	local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
	local lshift, rshift, arshift = bit.lshift, bit.rshift, bit.arshift

	ffi.cdef([[
typedef union {
	uint8_t u8[16]; int8_t i8[16];
	uint16_t u16[8]; int16_t i16[8];
	uint32_t u32[4]; int32_t i32[4];
	uint64_t u64[2]; int64_t i64[2];
} roc_v128;
]])
	local V = ffi.typeof("roc_v128")

	local UF = { [8] = "u8", [16] = "u16", [32] = "u32", [64] = "u64" }
	local SF = { [8] = "i8", [16] = "i16", [32] = "i32", [64] = "i64" }
	local function kind(w, s)
		return { w = w, n = 128 / w, s = s, uf = UF[w], sf = SF[w], f = s and SF[w] or UF[w], max = 2 ^ w - 1, smin = -2 ^ (w - 1), smax = 2 ^ (w - 1) - 1 }
	end
	local M = {
		u8x16 = kind(8, false), i8x16 = kind(8, true),
		u16x8 = kind(16, false), i16x8 = kind(16, true),
		u32x4 = kind(32, false), i32x4 = kind(32, true),
		u64x2 = kind(64, false), i64x2 = kind(64, true),
	}
	local U8, I16, I32, U64 = M.u8x16, M.i16x8, M.i32x4, M.u64x2

	-- Wrap a number or uint64 cdata to a lane width's unsigned range.
	local function wrap(x, w)
		if w == 64 then return x end
		if type(x) == "cdata" then return (tonumber(band(x, 2 ^ w - 1))) end
		return x % 2 ^ w
	end
	-- The w-bit two's-complement pattern of a signed value, as the unsigned lane.
	local function from_signed(x, w)
		if w == 64 then return (ffi.cast("uint64_t", x)) end
		if type(x) == "cdata" then return (tonumber(band(x, 2 ^ w - 1))) end
		return x % 2 ^ w
	end
	local function clamp(x, lo, hi)
		if x < lo then return lo end
		if x > hi then return hi end
		return x
	end
	local function copy(a)
		local o = V()
		ffi.copy(o, a, 16)
		return o
	end

	function M.zero() return (V()) end
	-- Little-endian 16-bit limbs, the U128 representation (and literal form).
	function M.lit(...)
		local o = V()
		for i = 0, 7 do o.u16[i] = select(i + 1, ...) end
		return o
	end
	function M.from_u128_bits(x)
		local o = V()
		for i = 0, 7 do o.u16[i] = x[i + 1] end
		return o
	end
	function M.to_u128_bits(a)
		local r = {}
		for i = 0, 7 do r[i + 1] = a.u16[i] end
		return r
	end

	function M.splat(R, value)
		local o, f = V(), R.f
		for i = 0, R.n - 1 do o[f][i] = value end
		return o
	end
	function M.get_lane(A, a, index) return a[A.f][tonumber(index)] end
	function M.with_lane(A, a, index, value)
		local o = copy(a)
		o[A.f][tonumber(index)] = value
		return o
	end

	local function map2(A, a, b, f)
		local o, uf = V(), A.uf
		for i = 0, A.n - 1 do o[uf][i] = f(A, a, b, i) end
		return o
	end
	local function raw(A, v, i) return v[A.uf][i] end
	local function sgn(A, v, i) return v[A.sf][i] end

	function M.add_wrap(A, a, b) return (map2(A, a, b, function(K, x, y, i) return wrap(raw(K, x, i) + raw(K, y, i), K.w) end)) end
	function M.sub_wrap(A, a, b) return (map2(A, a, b, function(K, x, y, i) return wrap(raw(K, x, i) - raw(K, y, i), K.w) end)) end
	function M.mul_wrap(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			if K.w == 32 then return (tonumber(band((0ULL + raw(K, x, i)) * raw(K, y, i), 0xffffffffULL))) end
			return (wrap(raw(K, x, i) * raw(K, y, i), K.w))
		end))
	end
	function M.add_sat(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			if K.s then return (from_signed(clamp(sgn(K, x, i) + sgn(K, y, i), K.smin, K.smax), K.w)) end
			return (math.min(raw(K, x, i) + raw(K, y, i), K.max))
		end))
	end
	function M.sub_sat(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			if K.s then return (from_signed(clamp(sgn(K, x, i) - sgn(K, y, i), K.smin, K.smax), K.w)) end
			local p, q = raw(K, x, i), raw(K, y, i)
			if p < q then return 0 end
			return p - q
		end))
	end
	local function neg_lane(K, x, _, i)
		if K.w == 64 then return 0ULL - raw(K, x, i) end
		return (-raw(K, x, i)) % 2 ^ K.w
	end
	function M.neg_wrap(A, a) return (map2(A, a, nil, neg_lane)) end
	function M.abs_wrap(A, a)
		return (map2(A, a, nil, function(K, x, _, i)
			if sgn(K, x, i) < 0 then return (neg_lane(K, x, nil, i)) end
			return (raw(K, x, i))
		end))
	end
	function M.min(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			local lt
			if K.s then lt = sgn(K, x, i) < sgn(K, y, i) else lt = raw(K, x, i) < raw(K, y, i) end
			if lt then return (raw(K, x, i)) end
			return (raw(K, y, i))
		end))
	end
	function M.max(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			local gt
			if K.s then gt = sgn(K, x, i) > sgn(K, y, i) else gt = raw(K, x, i) > raw(K, y, i) end
			if gt then return (raw(K, x, i)) end
			return (raw(K, y, i))
		end))
	end
	function M.abs_diff(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			local p, q = raw(K, x, i), raw(K, y, i)
			if p >= q then return p - q end
			return q - p
		end))
	end
	function M.avg_rounded(A, a, b)
		return (map2(A, a, b, function(K, x, y, i) return (floor((raw(K, x, i) + raw(K, y, i) + 1) / 2)) end))
	end
	local function lane_mask(K, yes)
		if not yes then return 0 end
		if K.w == 64 then return 0xffffffffffffffffULL end
		return K.max
	end
	function M.eq_lanes(A, a, b)
		return (map2(A, a, b, function(K, x, y, i) return (lane_mask(K, raw(K, x, i) == raw(K, y, i))) end))
	end
	function M.gt_lanes(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			if K.s then return (lane_mask(K, sgn(K, x, i) > sgn(K, y, i))) end
			return (lane_mask(K, raw(K, x, i) > raw(K, y, i)))
		end))
	end
	function M.gte_lanes(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			if K.s then return (lane_mask(K, sgn(K, x, i) >= sgn(K, y, i))) end
			return (lane_mask(K, raw(K, x, i) >= raw(K, y, i)))
		end))
	end

	-- 2^w * high-part of the lane product (arithmetic shift is floor division).
	function M.mul_high(A, a, b)
		return (map2(A, a, b, function(K, x, y, i)
			if K.s then return (from_signed(floor(sgn(K, x, i) * sgn(K, y, i) / 2 ^ K.w), K.w)) end
			return (floor(raw(K, x, i) * raw(K, y, i) / 2 ^ K.w))
		end))
	end
	function M.mul_q15_sat(_, a, b)
		local o = V()
		for i = 0, 7 do
			local v = floor((2 * a.i16[i] * b.i16[i] + 32768) / 65536)
			o.i16[i] = clamp(v, -32768, 32767)
		end
		return o
	end
	local function mul_wide(A, R, a, b, high)
		local o = V()
		local start = high and R.n or 0
		for i = 0, R.n - 1 do
			local x, y = start + i, start + i
			if A.s then
				local p
				if R.w == 64 then p = (0LL + sgn(A, a, x)) * sgn(A, b, y) else p = sgn(A, a, x) * sgn(A, b, y) end
				o[R.uf][i] = from_signed(p, R.w)
			else
				local p
				if R.w == 64 then p = (0ULL + raw(A, a, x)) * raw(A, b, y) else p = raw(A, a, x) * raw(A, b, y) end
				o[R.uf][i] = wrap(p, R.w)
			end
		end
		return o
	end
	function M.mul_wide_lo(A, R, a, b) return (mul_wide(A, R, a, b, false)) end
	function M.mul_wide_hi(A, R, a, b) return (mul_wide(A, R, a, b, true)) end
	function M.dot_pairs(_, a, b)
		local o = V()
		for i = 0, 3 do
			local v = a.i16[2 * i] * b.i16[2 * i] + a.i16[2 * i + 1] * b.i16[2 * i + 1]
			o.u32[i] = v % 2 ^ 32
		end
		return o
	end
	function M.dot_pairs_sat(_, a, b)
		local o = V()
		for i = 0, 7 do
			local v = a.u8[2 * i] * b.i8[2 * i] + a.u8[2 * i + 1] * b.i8[2 * i + 1]
			o.i16[i] = clamp(v, -32768, 32767)
		end
		return o
	end
	function M.sad(_, a, b)
		local o = V()
		for h = 0, 1 do
			local sum = 0
			for i = 0, 7 do
				local p, q = a.u8[h * 8 + i], b.u8[h * 8 + i]
				sum = sum + (p >= q and p - q or q - p)
			end
			o.u64[h] = sum
		end
		return o
	end

	local function bitwise(f, a, b)
		local o = V()
		for i = 0, 3 do o.i32[i] = f(a.i32[i], b.i32[i]) end
		return o
	end
	function M.band(a, b) return (bitwise(band, a, b)) end
	function M.bor(a, b) return (bitwise(bor, a, b)) end
	function M.bxor(a, b) return (bitwise(bxor, a, b)) end
	function M.bnot(a)
		local o = V()
		for i = 0, 3 do o.i32[i] = bnot(a.i32[i]) end
		return o
	end
	function M.bit_select(a, b, c)
		local o = V()
		for i = 0, 3 do
			local x = a.i32[i]
			o.i32[i] = bor(band(x, b.i32[i]), band(bnot(x), c.i32[i]))
		end
		return o
	end

	function M.bitmask(A, a)
		local out = 0
		for i = 0, A.n - 1 do
			if sgn(A, a, i) < 0 then out = out + 2 ^ i end
		end
		return out
	end

	-- `count` is a U8; the shift amount is count mod the lane width.
	function M.shl_wrap(A, a, count)
		local c = count % A.w
		return (map2(A, a, nil, function(K, x, _, i)
			if K.w == 64 then return (lshift(raw(K, x, i), c)) end
			return (raw(K, x, i) % 2 ^ (K.w - c)) * 2 ^ c
		end))
	end
	function M.shr_wrap(A, a, count)
		local c = count % A.w
		return (map2(A, a, nil, function(K, x, _, i)
			if not K.s then
				if K.w == 64 then return (rshift(raw(K, x, i), c)) end
				return (floor(raw(K, x, i) / 2 ^ c))
			end
			if K.w == 64 then return (from_signed(arshift(sgn(K, x, i), c), 64)) end
			return (from_signed(floor(sgn(K, x, i) / 2 ^ c), K.w))
		end))
	end
	function M.shr_zf_wrap(A, a, count)
		local c = count % A.w
		return (map2(A, a, nil, function(K, x, _, i)
			if K.w == 64 then return (rshift(raw(K, x, i), c)) end
			return (floor(raw(K, x, i) / 2 ^ c))
		end))
	end
	-- Only I16x8 and I32x4 expose it, so lanes are numbers.
	function M.shr_rounded(A, a, count)
		if count == 0 then return a end
		if count >= A.w then return V() end
		local bias = 2 ^ (count - 1)
		return (map2(A, a, nil, function(K, x, _, i)
			return (from_signed(floor((sgn(K, x, i) + bias) / 2 ^ count), K.w))
		end))
	end

	local function interleave(A, a, b, high)
		local o, uf = V(), A.uf
		local half = A.n / 2
		local start = high and half or 0
		for i = 0, half - 1 do
			o[uf][2 * i] = a[uf][start + i]
			o[uf][2 * i + 1] = b[uf][start + i]
		end
		return o
	end
	function M.interleave_lo(A, a, b) return (interleave(A, a, b, false)) end
	function M.interleave_hi(A, a, b) return (interleave(A, a, b, true)) end
	local function parity(A, a, b, odd)
		local o, uf = V(), A.uf
		local half = A.n / 2
		local p = odd and 1 or 0
		for i = 0, half - 1 do
			o[uf][i] = a[uf][2 * i + p]
			o[uf][half + i] = b[uf][2 * i + p]
		end
		return o
	end
	function M.even_lanes(A, a, b) return (parity(A, a, b, false)) end
	function M.odd_lanes(A, a, b) return (parity(A, a, b, true)) end
	function M.reverse_lanes(A, a)
		local o, uf = V(), A.uf
		for i = 0, A.n - 1 do o[uf][i] = a[uf][A.n - 1 - i] end
		return o
	end
	function M.table_lookup(_, a, b)
		local o = V()
		for i = 0, 15 do
			local index = b.u8[i]
			o.u8[i] = index < 16 and a.u8[index] or 0
		end
		return o
	end
	-- Bytes count.. of the 32-byte concatenation a ++ b (count <= 16 is checked
	-- by the Roc wrapper).
	function M.concat_shift_bytes(a, b, count)
		if count == 0 then return a end
		if count == 16 then return b end
		local o = V()
		for i = 0, 15 do
			local j = i + count
			o.u8[i] = j < 16 and a.u8[j] or b.u8[j - 16]
		end
		return o
	end

	local function widen(A, R, a, high)
		local o = V()
		local start = high and R.n or 0
		for i = 0, R.n - 1 do
			if A.s then
				o[R.sf][i] = sgn(A, a, start + i)
			else
				o[R.uf][i] = raw(A, a, start + i)
			end
		end
		return o
	end
	function M.widen_lo(A, R, a) return (widen(A, R, a, false)) end
	function M.widen_hi(A, R, a) return (widen(A, R, a, true)) end
	function M.pairwise_add_widen(A, R, a)
		local o = V()
		for i = 0, R.n - 1 do
			if A.s then
				o[R.uf][i] = from_signed(sgn(A, a, 2 * i) + sgn(A, a, 2 * i + 1), R.w)
			else
				o[R.uf][i] = wrap(raw(A, a, 2 * i) + raw(A, a, 2 * i + 1), R.w)
			end
		end
		return o
	end
	local function narrow(A, R, a, b, saturated)
		local o = V()
		local half = A.n
		for i = 0, R.n - 1 do
			local src = i < half and a or b
			local j = i % half
			local v
			if not saturated then
				v = wrap(raw(A, src, j), R.w)
			elseif R.s then
				v = from_signed(clamp(sgn(A, src, j), R.smin, R.smax), R.w)
			elseif A.s then
				local s = sgn(A, src, j)
				if s <= 0 then v = 0 else v = math.min(s, R.max) end
			else
				v = math.min(raw(A, src, j), R.max)
			end
			o[R.uf][i] = v
		end
		return o
	end
	function M.narrow_wrap(A, R, a, b) return (narrow(A, R, a, b, false)) end
	function M.narrow_sat(A, R, a, b) return (narrow(A, R, a, b, true)) end

	-- Sum of lanes as an exact number (lanes up to 32 bits) or a wrapping
	-- 64-bit cdata sum; the emitter converts to the result scalar.
	function M.sum_lanes(A, a)
		local sum = A.w == 64 and (A.s and 0LL or 0ULL) or 0
		local f = A.s and A.sf or A.uf
		for i = 0, A.n - 1 do sum = sum + a[f][i] end
		return sum
	end

	-- Carry-less 64x64 -> 128 product of lane h of a and b.
	local function clmul(a, b, h)
		local x, y = a.u64[h], b.u64[h]
		local lo, hi = 0ULL, 0ULL
		for i = 0, 63 do
			if band(rshift(y, i), 1ULL) ~= 0ULL then
				lo = bxor(lo, lshift(x, i))
				if i > 0 then hi = bxor(hi, rshift(x, 64 - i)) end
			end
		end
		local o = V()
		o.u64[0], o.u64[1] = lo, hi
		return o
	end
	function M.clmul_lo(a, b) return (clmul(a, b, 0)) end
	function M.clmul_hi(a, b) return (clmul(a, b, 1)) end

	-- List(U8) memory operations (interpreter evalSimdLoad/Store/Append).
	function M.load(list, index)
		local o = V()
		local a, base = list[1], list[2] + tonumber(index)
		for i = 0, 15 do o.u8[i] = a[base + i + 1] end
		return o
	end
	function M.store(v, list, index, in_place)
		local l = in_place and list or L.make_unique(list, 1, nil, nil)
		local a, base = l[1], l[2] + tonumber(index)
		for i = 0, 15 do a[base + i + 1] = v.u8[i] end
		return l
	end
	function M.append(v, list, in_place)
		local l = L.reserve(list, 16, 1, nil, nil, in_place)
		for i = 0, 15 do l = L.append_unsafe(l, v.u8[i]) end
		return l
	end

	M.V = V
	return M
end
