-- F32/F64 for the roc_luajit runtime. F64 is a Lua number; F32 is a Lua number
-- that always holds a value exactly representable as binary32 (every result
-- is rounded through an FFI float store).
--
-- Formatting reproduces Roc's floatToStrBytes (builtins/compiler_rt_128.zig
-- formatFloatDecimal over vendor/ryu.zig). Ryu's 128-bit table arithmetic is
-- replaced by exact big integers (wide.lua): starting from the exact scaled
-- value, Ryu's digit-removal loop yields the same shortest digits, rounding
-- decision and exponent, because every quantity Ryu approximates is computed
-- exactly here.
return function(W)
	local ffi = require("ffi")
	local bit = require("bit")
	local M = {}

	local cell = ffi.new("union { double d; uint64_t u; float f; uint32_t w; }")

	-- Round a Lua number to the nearest binary32 value (ties to even).
	function M.f32(x)
		cell.f = x
		return cell.f
	end

	-- NaNs: LuaJIT NaN-tags its values, so reading a non-canonical NaN out of an
	-- FFI cell can yield a non-number. NaN bit patterns are therefore mapped to
	-- LuaJIT's own NaN before reading, and to_bits returns Roc's canonical
	-- quiet NaN (builtins/float_bits.zig normalizeF*NanBits). Roc normalizes
	-- NaN bits and prints every NaN as "nan", so no program can tell.
	local NAN = 0 / 0
	local F64_NAN_BITS, F32_NAN_BITS = 0x7ff8000000000000ULL, 0x7fc00000

	-- Raw bits (for formatting); NaN sign and payload as the hardware left them.
	function M.f64_raw_bits(x)
		cell.d = x
		return cell.u
	end
	function M.f32_raw_bits(x)
		cell.f = x
		return cell.w
	end
	function M.f64_bits(x)
		if x ~= x then return F64_NAN_BITS end
		return (M.f64_raw_bits(x))
	end
	function M.f32_bits(x)
		if x ~= x then return F32_NAN_BITS end
		return (M.f32_raw_bits(x))
	end
	function M.f64_from_bits(u)
		u = ffi.cast("uint64_t", u)
		if bit.band(u, 0x7fffffffffffffffULL) > 0x7ff0000000000000ULL then return NAN end
		cell.u = u
		return cell.d
	end
	function M.f32_from_bits(w)
		w = tonumber(w)
		if w % 2 ^ 31 > 0x7f800000 then return NAN end
		cell.w = w
		return cell.f
	end

	-- Big-integer helpers over limb arrays of a fixed width n.
	local function big(v, n) return (W.from_small(v, n)) end
	local function add_small(a, v) return (W.add(a, W.from_small(v, #a))) end
	local function sub_small(a, v) return (W.sub(a, W.from_small(v, #a))) end
	local function mul_small(a, v)
		local r, carry = {}, 0
		for i = 1, #a do
			local p = a[i] * v + carry
			r[i] = p % 65536
			carry = math.floor(p / 65536)
		end
		return r
	end
	local function div10(a) return W.divmod_small(a, 10) end

	-- Shortest round-trip decimal of a finite non-zero float: digits (a
	-- string) and the decimal exponent of the last digit. `m`, `e2` give the
	-- value m * 2^e2; `accept` is Ryu's acceptBounds (m even); `mm_shift` is 1
	-- unless the lower neighbour is closer (mantissa field 0, exponent > 1).
	local function shortest(m, e2, accept, mm_shift)
		local shift = e2 - 2
		local n = math.ceil((64 + math.max(shift, 0) + (shift < 0 and math.ceil(-shift * 2.33) or 0)) / 16) + 2
		local mv = mul_small(big(m, n), 4)
		local mp = add_small(mv, 2)
		local mm = sub_small(mv, 1 + mm_shift)
		local q = 0
		if shift >= 0 then
			mv, mp, mm = W.shl(mv, shift), W.shl(mp, shift), W.shl(mm, shift)
		else
			-- x / 2^k = x * 5^k / 10^k
			for _ = 1, -shift do
				mv, mp, mm = mul_small(mv, 5), mul_small(mp, 5), mul_small(mm, 5)
			end
			q = shift
		end
		local vr, vp, vm = mv, mp, mm
		local vm_trailing = accept -- exact start: vm is exact, so only acceptance matters
		local vr_trailing = true
		if not accept then vp = sub_small(vp, 1) end
		local last = 0
		local removed = 0
		while true do
			local vp10 = div10(vp)
			local vm10, vm_rem = div10(vm)
			if W.cmp(vp10, vm10) <= 0 then break end
			vm_trailing = vm_trailing and vm_rem == 0
			vr_trailing = vr_trailing and last == 0
			local vr10, vr_rem = div10(vr)
			last = vr_rem
			vr, vp, vm = vr10, vp10, vm10
			removed = removed + 1
		end
		if vm_trailing then
			while true do
				local vm10, vm_rem = div10(vm)
				if vm_rem ~= 0 then break end
				vr_trailing = vr_trailing and last == 0
				local vr10, vr_rem = div10(vr)
				last = vr_rem
				vr, vm = vr10, vm10
				vp = div10(vp)
				removed = removed + 1
			end
		end
		if vr_trailing and last == 5 and vr[1] % 2 == 0 then last = 4 end
		local round_up = (W.cmp(vr, vm) == 0 and (not accept or not vm_trailing)) or last >= 5
		local out = round_up and add_small(vr, 1) or vr
		return W.to_decimal(out), q + removed
	end

	-- formatFloatDecimal: sign, digits and exponent laid out as Roc prints them.
	local function layout(negative, digits, exponent)
		local sign = negative and "-" or ""
		local olength = #digits
		local dp = exponent + olength
		if dp > 16 or dp <= -4 then
			local mant = digits:sub(1, 1)
			if olength > 1 then mant = mant .. "." .. digits:sub(2) end
			return sign .. mant .. "e" .. tostring(dp - 1)
		elseif dp <= 0 then
			return sign .. "0." .. string.rep("0", -dp) .. digits
		elseif dp >= olength then
			return sign .. digits .. string.rep("0", dp - olength)
		end
		return sign .. digits:sub(1, dp) .. "." .. digits:sub(dp + 1)
	end

	local function format(negative, ieee_m, ieee_e, mbits, ebits)
		local bias = 2 ^ (ebits - 1) - 1
		if ieee_e == 2 ^ ebits - 1 then
			if ieee_m ~= 0 then return "nan" end
			return negative and "-inf" or "inf"
		end
		if ieee_e == 0 and ieee_m == 0 then return negative and "-0" or "0" end
		local m, e2
		if ieee_e == 0 then
			m, e2 = ieee_m, 1 - bias - mbits
		else
			m, e2 = ieee_m + 2 ^ mbits, ieee_e - bias - mbits
		end
		local accept = m % 2 == 0
		local mm_shift = (ieee_m ~= 0 or ieee_e <= 1) and 1 or 0
		local digits, exponent = shortest(m, e2, accept, mm_shift)
		return (layout(negative, digits, exponent))
	end

	function M.f64_to_str(x)
		local u = M.f64_raw_bits(x)
		local negative = bit.rshift(u, 63) ~= 0ULL
		local ieee_e = tonumber(bit.band(bit.rshift(u, 52), 0x7ffULL))
		local ieee_m = tonumber(bit.band(u, 0xfffffffffffffULL))
		return (format(negative, ieee_m, ieee_e, 52, 11))
	end

	function M.f32_to_str(x)
		local w = tonumber(M.f32_raw_bits(x))
		local negative = w >= 2 ^ 31
		local ieee_e = math.floor(w / 2 ^ 23) % 256
		local ieee_m = w % 2 ^ 23
		return (format(negative, ieee_m, ieee_e, 23, 8))
	end

	-- Exact conversions ----------------------------------------------------------

	local LIMBS = 24 -- 384 bits: room for 128-bit values shifted by a 64-bit significand

	local function shl(a, s) return (W.shl(W.resize(a, LIMBS), s)) end

	-- Round the positive rational n / d (limb arrays) to a float with a p-bit
	-- significand, ties to even; returns +inf past the format's maximum.
	local function round_rational(n, d, p, max_exp)
		n, d = W.resize(n, LIMBS), W.resize(d, LIMBS)
		local e = W.bit_length(n) - W.bit_length(d) - p
		-- Scale so that the quotient has exactly p or p+1 bits.
		local sn, sd = n, d
		if e >= 0 then sd = shl(d, e) else sn = shl(n, -e) end
		local q, r = W.divmod(sn, sd)
		if W.bit_length(q) > p then
			e = e + 1
			if e >= 0 then sd = shl(d, e); sn = n else sd = d; sn = shl(n, -e) end
			q, r = W.divmod(sn, sd)
		end
		local twice = W.shl(r, 1)
		local c = W.cmp(twice, sd)
		local qn = 0
		for i = LIMBS, 1, -1 do qn = qn * 65536 + q[i] end
		if c > 0 or (c == 0 and qn % 2 == 1) then qn = qn + 1 end
		if e + W.bit_length(W.from_small(qn, 8)) > max_exp then return math.huge end
		return (math.ldexp(qn, e))
	end

	local ONE = W.from_small(1, LIMBS)

	-- Correctly rounded float (ties to even, subnormals included) of the
	-- positive value mag * 2^e2 * 10^e10, or math.huge past the format's
	-- range. Operand sizes follow the inputs, so any exact decimal or hex
	-- literal rounds once, as parseFloat's Eisel-Lemire and slow paths do.
	function M.round_scaled(mag, e2, e10, is_f32)
		local p, emin, max_exp = 53, -1074, 1024
		if is_f32 then p, emin, max_exp = 24, -149, 128 end
		local limbs = math.ceil((W.bit_length(mag) + math.abs(e10) * 4 + 16) / 16) + 1
		local n, d = W.resize(mag, limbs), W.from_small(1, limbs)
		if e10 >= 0 then
			for _ = 1, e10 do n = mul_small(n, 10) end
		else
			for _ = 1, -e10 do d = mul_small(d, 10) end
		end
		-- value = n / d * 2^e2; q = n / d * 2^(e2 - e) for the result's lsb exponent e.
		local nbits, dbits = W.bit_length(n), W.bit_length(d)
		local function quotient(e)
			local s = e2 - e
			local size = math.ceil((math.max(nbits + math.max(s, 0), dbits + math.max(-s, 0)) + 32) / 16)
			local sn, sd = W.resize(n, size), W.resize(d, size)
			if s >= 0 then sn = W.shl(sn, s) else sd = W.shl(sd, -s) end
			local q, r = W.divmod(sn, sd)
			return q, r, sd
		end
		local e = nbits - dbits + e2 - p
		if e < emin then e = emin end
		local q, r, sd = quotient(e)
		if W.bit_length(q) > p then
			e = e + 1
			q, r, sd = quotient(e)
		end
		local c = W.cmp(W.shl(r, 1), sd)
		local qn = 0
		for i = #q, 1, -1 do qn = qn * 65536 + q[i] end
		if c > 0 or (c == 0 and qn % 2 == 1) then qn = qn + 1 end
		if qn == 0 then return 0 end
		local _, qbits = math.frexp(qn)
		if e + qbits > max_exp then return math.huge end
		return (math.ldexp(qn, e))
	end

	-- Integer (sign, magnitude limbs) to F64 or F32: @floatFromInt, one rounding.
	function M.int_to_float(negative, magnitude, is_f32)
		if W.is_zero(magnitude) then return 0 end
		local v = is_f32 and round_rational(magnitude, ONE, 24, 128) or round_rational(magnitude, ONE, 53, 1024)
		if negative then v = -v end
		return v
	end

	-- floatToIntWrapBits: truncate, keep the low target bits, two's complement
	-- for negative values; NaN, infinities and subnormals give 0. Returns the
	-- bit pattern as 9 canonical-style limbs (unsigned, low 128 bits valid).
	function M.float_to_int_bits(x, is_f32, target_bits)
		local raw, fraction_bits, bias, exp_mask
		if is_f32 then
			raw = W.from_small(tonumber(M.f32_raw_bits(x)), 8)
			fraction_bits, bias, exp_mask = 23, 127, 255
		else
			local u = M.f64_raw_bits(x)
			raw = {}
			for i = 1, 4 do raw[i] = tonumber(bit.band(bit.rshift(u, 16 * (i - 1)), 0xffff)) end
			for i = 5, 8 do raw[i] = 0 end
			fraction_bits, bias, exp_mask = 52, 1023, 2047
		end
		local shifted = W.shr(raw, fraction_bits)
		local exponent = shifted[1] % (exp_mask + 1)
		if exponent == exp_mask or exponent == 0 then return (W.zero(8)) end
		local negative = math.floor(shifted[1] / (exp_mask + 1)) % 2 == 1
		local fraction = W.zero(8)
		local mask_bits = W.sub(W.shl(W.from_small(1, 8), fraction_bits), W.from_small(1, 8))
		for i = 1, 8 do fraction[i] = bit.band(raw[i], mask_bits[i]) end
		local significand = W.add(fraction, W.shl(W.from_small(1, 8), fraction_bits))
		local shift = exponent - bias - fraction_bits
		local magnitude
		if shift >= 0 then
			if shift >= target_bits then return (W.zero(8)) end
			magnitude = W.shl(significand, shift)
		else
			if -shift >= 128 then return (W.zero(8)) end
			magnitude = W.shr(significand, -shift)
		end
		if target_bits < 128 then
			local m = W.sub(W.shl(W.from_small(1, 8), target_bits), W.from_small(1, 8))
			for i = 1, 8 do magnitude[i] = bit.band(magnitude[i], m[i]) end
		end
		if negative then
			magnitude = W.neg(magnitude)
			if target_bits < 128 then
				local m = W.sub(W.shl(W.from_small(1, 8), target_bits), W.from_small(1, 8))
				for i = 1, 8 do magnitude[i] = bit.band(magnitude[i], m[i]) end
			end
		end
		return magnitude
	end

	-- Dec (scaled i128 bits, as sign + magnitude limbs) to F64: i128_to_f64 then
	-- one division by 10^18, exactly as RocDec.toF64 does.
	local DEC_SCALE = W.from_decimal("1000000000000000000", LIMBS)
	function M.dec_to_f64(negative, magnitude)
		local whole = M.int_to_float(negative, magnitude, false)
		return whole / 1e18
	end
	-- Dec to F32: scaledI128ToF32, the correctly rounded quotient.
	function M.dec_to_f32(negative, magnitude)
		if W.is_zero(magnitude) then return 0 end
		local v = round_rational(magnitude, DEC_SCALE, 24, 128)
		if negative then v = -v end
		return v
	end

	return M
end
