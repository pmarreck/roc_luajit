-- I128, U128 and Dec for the roc_luajit runtime, built on the exact 16-bit
-- limb core (W). A value is an 8-limb array; I128 and Dec read it as two's
-- complement. Dec is an I128 scaled by 10^18 (src/builtins/dec.zig).
-- Algorithms follow the Zig builtins so results match them bit for bit.
return function(W)
	local M = {}
	local bit = require("bit")
	local N = 8
	local TOP = 32768 -- sign bit of the top 16-bit limb

	local function is_neg(a) return a[N] >= TOP end
	local function crash(message) error({ roc_crash = true, message = message }, 0) end
	M.set_crash = function(f) crash = f end

	local ZERO = W.zero(N)
	local I128_MAX = W.from_decimal("170141183460469231731687303715884105727", N)
	local MAG_MIN = W.from_decimal("170141183460469231731687303715884105728", N) -- |I128 min|

	-- Construct from eight 16-bit limbs, least significant first.
	function M.from_limbs(...) return { ... } end

	local function abs_u(a) if is_neg(a) then return (W.neg(a)) end return a end

	-- Wrapping and checked arithmetic -------------------------------------------

	function M.add_wrap(a, b) local r = W.add(a, b) return r end
	function M.sub_wrap(a, b) local r = W.sub(a, b) return r end
	function M.mul_wrap(a, b) return (W.resize(W.mul_full(a, b), N)) end

	function M.add_checked_i128(a, b, message)
		local r = W.add(a, b)
		if is_neg(a) == is_neg(b) and is_neg(r) ~= is_neg(a) then crash(message) end
		return r
	end

	function M.sub_checked_i128(a, b, message)
		local r = W.sub(a, b)
		if is_neg(a) ~= is_neg(b) and is_neg(r) ~= is_neg(a) then crash(message) end
		return r
	end

	function M.mul_checked_i128(a, b, message)
		local negative = is_neg(a) ~= is_neg(b)
		local p = W.mul_full(abs_u(a), abs_u(b))
		for i = N + 1, 2 * N do if p[i] ~= 0 then crash(message) end end
		local lo = W.resize(p, N)
		local limit = negative and MAG_MIN or I128_MAX
		if W.cmp(lo, limit) > 0 then crash(message) end
		if negative then return (W.neg(lo)) end
		return lo
	end

	function M.add_checked_u128(a, b, message)
		local r, carry = W.add(a, b)
		if carry ~= 0 then crash(message) end
		return r
	end

	function M.sub_checked_u128(a, b, message)
		local r, borrow = W.sub(a, b)
		if borrow ~= 0 then crash(message) end
		return r
	end

	function M.mul_checked_u128(a, b, message)
		local p = W.mul_full(a, b)
		for i = N + 1, 2 * N do if p[i] ~= 0 then crash(message) end end
		return (W.resize(p, N))
	end

	-- Comparison ------------------------------------------------------------------

	function M.cmp_u128(a, b) return (W.cmp(a, b)) end

	function M.cmp_i128(a, b)
		local na, nb = is_neg(a), is_neg(b)
		if na ~= nb then return na and -1 or 1 end
		return (W.cmp(a, b))
	end

	function M.eq(a, b) return W.cmp(a, b) == 0 end

	-- Formatting ------------------------------------------------------------------

	function M.u128_to_str(a) return (W.to_decimal(a)) end

	function M.i128_to_str(a)
		if is_neg(a) then return "-" .. W.to_decimal(W.neg(a)) end
		return (W.to_decimal(a))
	end

	-- Port of RocDec.format_to_buf: trailing fractional zeros are dropped, but at
	-- least one fractional digit is printed.
	local DECIMAL_PLACES = 18
	function M.dec_to_str(a)
		if W.is_zero(a) then return "0.0" end
		local negative = is_neg(a)
		local digits = W.to_decimal(abs_u(a))
		local n = #digits
		local out = {}
		if negative then out[#out + 1] = "-" end
		local before = 0
		if n > DECIMAL_PLACES then
			before = n - DECIMAL_PLACES
			out[#out + 1] = digits:sub(1, before)
		else
			out[#out + 1] = "0"
		end
		out[#out + 1] = "."
		local trailing = 0
		for i = n, 1, -1 do
			if digits:byte(i) == 48 then trailing = trailing + 1 else break end
		end
		if trailing >= DECIMAL_PLACES then
			out[#out + 1] = "0"
		else
			if n < DECIMAL_PLACES then out[#out + 1] = string.rep("0", DECIMAL_PLACES - n) end
			out[#out + 1] = digits:sub(before + 1, n - trailing)
		end
		return (table.concat(out))
	end

	-- Dec multiplication: port of RocDec.mulWithOverflow and mul_and_decimalize.
	-- The builtin computes the quotient by 10^18 as
	-- ((x + 1) * floor(2^315 / 10^18)) >> 315 rather than by true division; the
	-- argument below shows that equals floor(x / 10^18), which this port
	-- computes directly as two exact divisions by 10^9.
	-- With R = floor(2^315 / 10^18) = 2^315/10^18 - f (0 < f < 1, since 5 does
	-- not divide 2^315) and x + 1 <= 2^254, (x+1)*R / 2^315 = (x+1)/10^18 - e with
	-- 0 < e < 2^-61. Flooring that yields floor(x / 10^18) exactly: when 10^18
	-- divides x+1, e > 0 steps just below the integer; otherwise the fraction is
	-- at least 10^-18 > 2^-60 > e. Hence R - 1 (adding another e' < 2^-61) is an
	-- equivalent mutant, and the vector suite correctly cannot kill it.
	local ONE = W.from_decimal("1000000000000000000", N)
	-- Add vi * 10^18, shifted by `at` limbs, into the 8-limb r. vi < 2^16
	-- and every limb product is below 2^32, so the doubles stay exact.
	local floor = math.floor
	local function add_scaled_one(r, vi, at)
		local carry = 0
		for j = 1, 4 do
			local t = r[at + j] + vi * ONE[j] + carry
			carry = floor(t / 65536)
			r[at + j] = t - carry * 65536
		end
		local k = at + 5
		while carry ~= 0 and k <= N do
			local t = r[k] + carry
			carry = floor(t / 65536)
			r[k] = t - carry * 65536
			k = k + 1
		end
	end

	-- Dec from an integer-valued Lua number with |v| < 2^53: |v| * 10^18 (at
	-- most 2^113, so it fits) built limb by limb, negated for v < 0. One table.
	function M.dec_from_small_int(v)
		local negative = v < 0
		if negative then v = -v end
		local r = { 0, 0, 0, 0, 0, 0, 0, 0 }
		local at = 0
		while v > 0 do
			local vi = v % 65536
			if vi ~= 0 then add_scaled_one(r, vi, at) end
			v = (v - vi) / 65536
			at = at + 1
		end
		if negative then return (W.neg(r)) end
		return r
	end
	local BILLION = 1000000000
	local DEC_MIN = W.add(I128_MAX, W.from_small(1, N)) -- bit pattern of I128 min

	local function mul_and_decimalize(a, b)
		-- a, b: unsigned magnitudes below 2^127 (top bit clear).
		local shifted = W.mul_full(a, b) -- 256 bits, below 2^254
		W.div_small_in_place(shifted, BILLION) -- floor(x / 10^18), over the product
		W.div_small_in_place(shifted, BILLION)
		local overflow = false
		for i = N + 1, 2 * N do if shifted[i] ~= 0 then overflow = true end end
		local value = W.resize(shifted, N)
		if W.cmp(value, I128_MAX) > 0 then overflow = true end
		if overflow then return I128_MAX, true end
		return value, false
	end

	function M.dec_mul(a, b, message)
		local negative = is_neg(a) ~= is_neg(b)
		local ua, ub = abs_u(a), abs_u(b)
		if W.cmp(ua, I128_MAX) > 0 then -- a is Dec.min
			if W.is_zero(b) then return (W.copy(ZERO)) end
			if W.cmp(b, ONE) == 0 then return a end
			crash(message)
		end
		if W.cmp(ub, I128_MAX) > 0 then
			if W.is_zero(a) then return (W.copy(ZERO)) end
			if W.cmp(a, ONE) == 0 then return b end
			crash(message)
		end
		local value, overflow = mul_and_decimalize(ua, ub)
		if overflow then crash(message) end
		if negative then return (W.neg(value)) end
		return value
	end

	-- Dec division: truncating |n| * 10^18 / |d|, sign applied after.
	function M.dec_div(a, b)
		if W.is_zero(b) then crash("Decimal division by 0!") end
		if W.is_zero(a) then return (W.copy(ZERO)) end
		local negative = is_neg(a) ~= is_neg(b)
		local num = W.mul_full(abs_u(a), ONE) -- 256 bits
		local q = W.divmod(num, abs_u(b), true)
		for i = N + 1, 2 * N do if q[i] ~= 0 then crash("Decimal division overflow!") end end
		local lo = W.resize(q, N)
		if negative then
			if W.cmp(lo, MAG_MIN) > 0 then crash("Decimal division overflow!") end
			return (W.neg(lo))
		end
		if W.cmp(lo, I128_MAX) > 0 then crash("Decimal division overflow!") end
		return lo
	end

	-- Division family (semantics of the interpreter's intBinOp and RocDec) ------
	-- Unchecked forms return 0 for a zero divisor; signed MIN / -1 returns the
	-- dividend, and its remainder and modulo are 0. Checked forms crash with the
	-- messages the emitter passes in (lir/checked_arithmetic.zig).

	local MINUS_ONE = W.neg(W.from_small(1, N))

	-- Truncating signed quotient and remainder; b ~= 0 and not MIN / -1.
	local function sdivmod(a, b)
		local na, nb = is_neg(a), is_neg(b)
		local q, r = W.divmod(abs_u(a), abs_u(b))
		if na ~= nb then q = W.neg(q) end
		if na then r = W.neg(r) end
		return q, r
	end

	local function floor_mod(r, b, signed)
		if not signed or W.is_zero(r) or is_neg(r) == is_neg(b) then return r end
		return W.add(r, b)
	end

	for _, kind in ipairs({ "i128", "u128" }) do
		local signed = kind == "i128"
		local divmod = signed and sdivmod or W.divmod
		local function min_div(a, b) return signed and W.cmp(a, DEC_MIN) == 0 and W.cmp(b, MINUS_ONE) == 0 end
		M["div_trunc_" .. kind] = function(a, b)
			if W.is_zero(b) then return (W.copy(ZERO)) end
			if min_div(a, b) then return a end
			return (divmod(a, b))
		end
		M["div_trunc_checked_" .. kind] = function(a, b, zero_message, overflow_message)
			if W.is_zero(b) then crash(zero_message) end
			if min_div(a, b) then crash(overflow_message) end
			return (divmod(a, b))
		end
		local function rem(a, b)
			if W.is_zero(b) or min_div(a, b) then return (W.copy(ZERO)) end
			local _, r = divmod(a, b)
			return r
		end
		local function mod(a, b)
			if W.is_zero(b) or min_div(a, b) then return (W.copy(ZERO)) end
			local _, r = divmod(a, b)
			return floor_mod(r, b, signed)
		end
		M["rem_" .. kind] = rem
		M["mod_" .. kind] = mod
		M["rem_checked_" .. kind] = function(a, b, zero_message)
			if W.is_zero(b) then crash(zero_message) end
			return (rem(a, b))
		end
		M["mod_checked_" .. kind] = function(a, b, zero_message)
			if W.is_zero(b) then crash(zero_message) end
			return mod(a, b)
		end
		local cmp = signed and M.cmp_i128 or M.cmp_u128
		M["abs_diff_" .. kind] = function(a, b)
			if cmp(a, b) > 0 then return (W.sub(a, b)) end
			return (W.sub(b, a))
		end
		M["neg_wrap_" .. kind] = W.neg
		M["neg_checked_" .. kind] = function(a, message)
			if signed then
				if W.cmp(a, DEC_MIN) == 0 then crash(message) end
			elseif not W.is_zero(a) then
				crash(message)
			end
			return (W.neg(a))
		end
		M["abs_wrap_" .. kind] = function(a)
			if signed and is_neg(a) then return (W.neg(a)) end
			return a
		end
		M["abs_checked_" .. kind] = function(a, message)
			if signed and is_neg(a) then
				if W.cmp(a, DEC_MIN) == 0 then crash(message) end
				return (W.neg(a))
			end
			return a
		end
	end

	-- Dec: RocDec.div then trunc; rem and mod on the raw scaled values.
	function M.dec_div_trunc(a, b)
		local q = M.dec_div(a, b)
		local _, frac = sdivmod(q, ONE)
		return (W.sub(q, frac))
	end

	function M.dec_rem(a, b)
		if W.is_zero(b) then crash("Decimal remainder by 0!") end
		local _, r = sdivmod(a, b)
		return r
	end

	function M.dec_mod(a, b)
		if W.is_zero(b) then crash("Decimal modulo by 0!") end
		local _, r = sdivmod(a, b)
		return floor_mod(r, b, true)
	end

	M.neg_wrap_dec = W.neg
	M.abs_wrap_dec = M.abs_wrap_i128
	M.abs_checked_dec = M.abs_checked_i128
	M.abs_diff_dec = M.abs_diff_i128


	-- Dec transcendentals (builtins/dec.zig): the same integer algorithms on
	-- the same scaled values, so every result matches bit for bit, and the
	-- same crash messages.
	local DEC_PI = W.from_decimal("3141592653589793238", N)
	local DEC_TAU = W.from_decimal("6283185307179586476", N)
	local DEC_HALF_PI = W.from_decimal("1570796326794896619", N)
	local DEC_LN2 = W.from_decimal("693147180559945309", N)
	local DEC_TWO = W.add(ONE, ONE)
	local DEC_CORDIC_K = W.from_decimal("607252935008881256", N)
	M.DEC_PI, M.DEC_TAU, M.DEC_HALF_PI, M.DEC_LN2 = DEC_PI, DEC_TAU, DEC_HALF_PI, DEC_LN2
	local DEC_CORDIC_ATAN = {}
	for i, s in ipairs({
		"785398163397448309", "463647609000806116", "244978663126864154", "124354994546761435",
		"62418809995957348", "31239833430268276", "15623728620476830", "7812341060101111",
		"3906230131966971", "1953122516478818", "976562189559319", "488281211194898",
		"244140620149361", "122070311893670", "61035156174208", "30517578115526",
		"15258789061315", "7629394531101", "3814697265606", "1907348632810",
		"953674316405", "476837158203", "238418579101", "119209289550",
		"59604644775", "29802322387", "14901161193", "7450580596",
		"3725290298", "1862645149", "931322574", "465661287",
		"232830643", "116415321", "58207660", "29103830",
		"14551915", "7275957", "3637978", "1818989",
		"909494", "454747", "227373", "113686",
		"56843", "28421", "14210", "7105",
		"3552", "1776", "888", "444",
		"222", "111", "55", "27",
		"13", "6", "3", "1",
		"0", "0", "0", "0",
	}) do DEC_CORDIC_ATAN[i] = W.from_decimal(s, N) end

	local function dec_add(a, b) return (M.add_checked_i128(a, b, "Decimal addition overflowed!")) end
	local function dec_sub(a, b) return (M.sub_checked_i128(a, b, "Decimal subtraction overflowed!")) end
	local function dec_mul(a, b) return (M.dec_mul(a, b, "Decimal multiplication overflowed!")) end
	local dec_div = M.dec_div
	local function scmp(a, b) return (M.cmp_i128(a, b)) end

	-- i128h.shr_i128: arithmetic right shift.
	local ALL_ONES = W.neg(W.from_small(1, N))
	local function ashr(a, s)
		if s == 0 then return a end
		local r = W.shr(a, s)
		if is_neg(a) then
			local fill = s >= 128 and ALL_ONES or W.shl(ALL_ONES, 128 - s)
			for i = 1, N do r[i] = bit.bor(r[i], fill[i]) end
		end
		return r
	end

	-- RocDec.fract / trunc.
	local function dec_fract(a)
		local _, r = W.divmod(abs_u(a), ONE)
		if is_neg(a) then return (W.neg(r)) end
		return r
	end
	local function dec_trunc(a) return (dec_sub(a, dec_fract(a))) end
	local function from_whole(v)
		local w = W.from_small(math.abs(v), N)
		if v < 0 then w = W.neg(w) end
		return (W.resize(W.mul_full(w, ONE), N))
	end

	-- decSinCos: reduce into [-pi/2, pi/2], then CORDIC rotation.
	local function sin_cos(value)
		local _, angle = sdivmod(value, DEC_TAU)
		if scmp(angle, DEC_PI) > 0 then
			angle = W.sub(angle, DEC_TAU)
		elseif scmp(angle, W.neg(DEC_PI)) < 0 then
			angle = W.add(angle, DEC_TAU)
		end
		local cos_negative = false
		if scmp(angle, DEC_HALF_PI) > 0 then
			angle = W.sub(DEC_PI, angle)
			cos_negative = true
		elseif scmp(angle, W.neg(DEC_HALF_PI)) < 0 then
			angle = W.sub(W.neg(DEC_PI), angle)
			cos_negative = true
		end
		local x, y, z = DEC_CORDIC_K, W.copy(ZERO), angle
		for i = 1, #DEC_CORDIC_ATAN do
			local xs, ys = ashr(x, i - 1), ashr(y, i - 1)
			if not is_neg(z) then
				x, y, z = W.sub(x, ys), W.add(y, xs), W.sub(z, DEC_CORDIC_ATAN[i])
			else
				x, y, z = W.add(x, ys), W.sub(y, xs), W.add(z, DEC_CORDIC_ATAN[i])
			end
		end
		if cos_negative then x = W.neg(x) end
		return y, x
	end

	-- decAtanReduced: vectoring CORDIC from (1, value).
	local function atan_reduced(value)
		local x, y, z = W.copy(ONE), value, W.copy(ZERO)
		for i = 1, #DEC_CORDIC_ATAN do
			if W.is_zero(y) then break end
			local xs, ys = ashr(x, i - 1), ashr(y, i - 1)
			if not is_neg(y) then
				x, y, z = W.add(x, ys), W.sub(y, xs), W.add(z, DEC_CORDIC_ATAN[i])
			else
				x, y, z = W.sub(x, ys), W.add(y, xs), W.sub(z, DEC_CORDIC_ATAN[i])
			end
		end
		return z
	end

	-- decSqrtNonNegative: floor(sqrt(value * 10^18)) (intSqrtU256's answer).
	local function sqrt_non_negative(value)
		local scaled = W.mul_full(value, ONE) -- 256 bits
		if W.is_zero(scaled) then return (W.copy(ZERO)) end
		-- Newton's method from above converges to the floor square root.
		local x = W.shl(W.from_small(1, 2 * N), math.floor((W.bit_length(scaled) + 1) / 2) + 1)
		while true do
			local q = W.divmod(scaled, x)
			local y = W.shr(W.add(x, q), 1)
			if W.cmp(y, x) >= 0 then break end
			x = y
		end
		return (W.resize(x, N))
	end

	-- decLnPositive: halve or double into [1, 2), then 2 * atanh series.
	local function ln_positive(value)
		if is_neg(value) or W.is_zero(value) then crash("Decimal log is undefined for non-positive input!") end
		local reduced, power = value, 0
		while scmp(reduced, DEC_TWO) >= 0 do
			reduced = dec_div(reduced, DEC_TWO)
			power = power + 1
		end
		while scmp(reduced, ONE) < 0 do
			reduced = dec_mul(reduced, DEC_TWO)
			power = power - 1
		end
		local z = dec_div(dec_sub(reduced, ONE), dec_add(reduced, ONE))
		local z2 = dec_mul(z, z)
		local term, sum, divisor = z, W.copy(ZERO), 1
		while not W.is_zero(term) do
			local nxt = dec_div(term, from_whole(divisor))
			if W.is_zero(nxt) then break end
			sum = dec_add(sum, nxt)
			term = dec_mul(term, z2)
			divisor = divisor + 2
		end
		local result = dec_mul(DEC_TWO, sum)
		if power ~= 0 then result = dec_add(result, dec_mul(from_whole(power), DEC_LN2)) end
		return result
	end

	-- decExp: reduce by ln 2, Taylor series, then scale by 2^k.
	local function exp(value)
		local whole = dec_trunc(dec_div(value, DEC_LN2))
		local q = W.divmod(abs_u(whole), ONE)
		local k = 0
		for i = N, 1, -1 do k = k * 65536 + q[i] end
		if is_neg(whole) then k = -k end
		local reduced = dec_sub(value, dec_mul(whole, DEC_LN2))
		local sum, term, divisor = W.copy(ONE), W.copy(ONE), 1
		while true do
			local nxt = dec_div(dec_mul(term, reduced), from_whole(divisor))
			if W.is_zero(nxt) then break end
			sum = dec_add(sum, nxt)
			term = nxt
			divisor = divisor + 1
		end
		local result = sum
		while k > 0 do
			result = dec_mul(result, DEC_TWO)
			k = k - 1
		end
		while k < 0 and not W.is_zero(result) do
			result = dec_div(result, DEC_TWO)
			k = k + 1
		end
		return result
	end

	-- RocDec.powInt with an I128 exponent (limbs).
	local MINUS_ONE_I = W.neg(W.from_small(1, N))
	local function pow_int(base, e)
		if W.is_zero(e) then return (W.copy(ONE)) end
		if not is_neg(e) then
			if e[1] % 2 == 0 then
				local half = pow_int(base, ashr(e, 1))
				return (dec_mul(half, half))
			end
			return (dec_mul(base, pow_int(base, W.add(e, MINUS_ONE_I))))
		end
		return (dec_div(W.copy(ONE), pow_int(base, W.neg(e))))
	end

	function M.dec_sin(a) return (sin_cos(a)) end
	function M.dec_cos(a)
		local _, c = sin_cos(a)
		return c
	end
	function M.dec_tan(a)
		local s, c = sin_cos(a)
		return (dec_div(s, c))
	end
	function M.dec_atan(a)
		if scmp(a, ONE) > 0 then
			return (dec_sub(DEC_HALF_PI, atan_reduced(dec_div(ONE, a))))
		end
		if scmp(a, W.neg(ONE)) < 0 then
			return (dec_sub(W.neg(DEC_HALF_PI), atan_reduced(dec_div(ONE, a))))
		end
		return (atan_reduced(a))
	end
	function M.dec_sqrt(a)
		if is_neg(a) then crash("Decimal square root of a negative number!") end
		return (sqrt_non_negative(a))
	end
	function M.dec_asin(a)
		if scmp(a, ONE) > 0 or scmp(a, W.neg(ONE)) < 0 then crash("Decimal asin input is outside [-1, 1]!") end
		if W.cmp(a, ONE) == 0 then return (W.copy(DEC_HALF_PI)) end
		if W.cmp(a, W.neg(ONE)) == 0 then return (W.neg(DEC_HALF_PI)) end
		local complement = dec_sub(ONE, dec_mul(a, a))
		return (M.dec_atan(dec_div(a, M.dec_sqrt(complement))))
	end
	function M.dec_acos(a) return (dec_sub(DEC_HALF_PI, M.dec_asin(a))) end
	M.dec_log = ln_positive
	function M.dec_pow(base, e)
		if W.cmp(dec_trunc(e), e) == 0 then
			local q = W.divmod(abs_u(e), ONE)
			if is_neg(e) then q = W.neg(q) end
			return (pow_int(base, q))
		end
		if is_neg(base) or W.is_zero(base) then
			crash("Decimal power is undefined for non-positive base and fractional exponent!")
		end
		return (exp(dec_mul(ln_positive(base), e)))
	end

	-- Vectoring CORDIC on jointly normalized coordinates (RocDec.atan2).
	function M.dec_atan2(y_arg, x_arg)
		if W.is_zero(y_arg) then return is_neg(x_arg) and W.copy(DEC_PI) or W.copy(ZERO) end
		if W.is_zero(x_arg) then return is_neg(y_arg) and W.neg(DEC_HALF_PI) or W.copy(DEC_HALF_PI) end
		local ax, ay = abs_u(x_arg), abs_u(y_arg)
		local bits = math.max(W.bit_length(ax), W.bit_length(ay))
		local leading = 128 - bits
		local x, y
		if leading >= 7 then
			x, y = W.shl(ax, leading - 7), W.shl(ay, leading - 7)
		else
			x, y = W.shr(ax, 7 - leading), W.shr(ay, 7 - leading)
		end
		local angle = W.copy(ZERO)
		for i = 1, #DEC_CORDIC_ATAN do
			if W.is_zero(y) then break end
			local dx, dy = ashr(x, i - 1), ashr(y, i - 1)
			if not is_neg(y) then
				x, y, angle = W.add(x, dy), W.sub(y, dx), W.add(angle, DEC_CORDIC_ATAN[i])
			else
				x, y, angle = W.sub(x, dy), W.add(y, dx), W.sub(angle, DEC_CORDIC_ATAN[i])
			end
		end
		if is_neg(x_arg) then angle = W.sub(DEC_PI, angle) end
		if is_neg(y_arg) then return (W.neg(angle)) end
		return angle
	end

	M.DEC_MIN = DEC_MIN
	return M
end
