-- Numeric parsing for the roc_luajit runtime: ports of builtins/num.zig
-- (integer and float token grammars, explicit-radix integers),
-- builtins/decimal_parse.zig (decimal integers and Dec) and the acceptance
-- rules of vendor/parse_float (Zig's parseFloat). Results are exact: integers
-- and Dec come back as sign plus a 9-limb magnitude, floats as the correctly
-- rounded value of the exact rational the token denotes, which is what
-- parseFloat's Eisel-Lemire and slow paths compute.
--
-- Byte strings are Lua strings; positions are 1-based, lengths are byte counts.
return function(W, F)
	local bit = require("bit")
	local floor = math.floor
	local byte = string.byte
	local M = {}

	local LIMBS = 9 -- 144 bits: every magnitude up to 2^128 plus headroom

	local function is_digit(b) return b ~= nil and b >= 48 and b <= 57 end

	-- digitValue: 0-9, then letters as 10.. in either case.
	local function digit_value(b)
		if b == nil then return nil end
		if b >= 48 and b <= 57 then return b - 48 end
		if b >= 97 and b <= 122 then return b - 87 end
		if b >= 65 and b <= 90 then return b - 55 end
		return nil
	end
	local function is_radix_digit(b, radix)
		local d = digit_value(b)
		return d ~= nil and d < radix
	end

	local function big(v) return (W.from_small(v, LIMBS)) end

	-- a * m + d for a small m and d, in a new array of #a limbs (the caller
	-- guarantees no overflow out of the top limb).
	local function mul_add(a, m, d)
		local out, carry = {}, d
		for k = 1, #a do
			local x = a[k] * m + carry
			out[k] = x % 65536
			carry = floor(x / 65536)
		end
		return out
	end
	local U128_MAX = W.sub(W.shl(big(1), 128), big(1))
	local U128_MAX_DIV10, U128_MAX_MOD10 = W.divmod_small(U128_MAX, 10)

	-- Largest magnitude per integer type ("max" positive, and the negative limit).
	local limits = {}
	for _, spec in ipairs({
		{ "u8", 8, false }, { "i8", 8, true }, { "u16", 16, false }, { "i16", 16, true },
		{ "u32", 32, false }, { "i32", 32, true }, { "u64", 64, false }, { "i64", 64, true },
		{ "u128", 128, false }, { "i128", 128, true },
	}) do
		local bits = spec[3] and spec[2] - 1 or spec[2]
		local max = W.sub(W.shl(big(1), bits), big(1))
		limits[spec[1]] = { signed = spec[3], max = max, neg = W.add(max, big(1)) }
	end

	-- decimal_parse.scanPrefix. `int_grammar` excludes the decimal point.
	-- The exponent magnitude saturates: any exponent past 10^16 is rejected by
	-- every consumer exactly as an overflowed u64 would be (zero coefficients
	-- are decided before the exponent is consulted).
	local EXP_SATURATE = 1e16
	local function scan_prefix(s, int_grammar)
		local n = #s
		local i = 1
		local first = byte(s, 1)
		local negative = first == 45
		if first == 45 or first == 43 then i = 2 end
		local had_point, saw_digit, saw_nonzero = false, false, false
		local cdigits, fdigits, lzeros, tzeros = 0, 0, 0, 0
		local coef, cov = big(0), false
		while i <= n do
			local b = byte(s, i)
			if b >= 48 and b <= 57 then
				local d = b - 48
				saw_digit = true
				cdigits = cdigits + 1
				if had_point then fdigits = fdigits + 1 end
				if not saw_nonzero and d == 0 then lzeros = lzeros + 1 else saw_nonzero = true end
				tzeros = d == 0 and tzeros + 1 or 0
				if not cov then
					local c = W.cmp(coef, U128_MAX_DIV10)
					if c > 0 or (c == 0 and d > U128_MAX_MOD10) then
						cov = true
					else
						coef = mul_add(coef, 10, d)
					end
				end
			elseif b == 95 then
				if i == 1 or not is_digit(byte(s, i - 1)) or i == n or not is_digit(byte(s, i + 1)) then break end
			elseif b == 46 then
				if int_grammar or had_point then break end
				had_point = true
			else
				break
			end
			i = i + 1
		end
		if not saw_digit then return nil end
		local mantissa_end = i - 1

		local eneg, emag, eov = false, 0, false
		local b = byte(s, i)
		if b == 101 or b == 69 then
			local c = i + 1
			local cand = false
			local sb = byte(s, c)
			if sb == 43 or sb == 45 then
				cand = sb == 45
				c = c + 1
			end
			if is_digit(byte(s, c)) then
				local mag, ov = 0, false
				while c <= n do
					local x = byte(s, c)
					if is_digit(x) then
						if not ov then
							mag = mag * 10 + (x - 48)
							if mag > EXP_SATURATE then ov = true end
						end
					elseif x == 95 and is_digit(byte(s, c - 1)) and c + 1 <= n and is_digit(byte(s, c + 1)) then
						-- separator between exponent digits
					else
						break
					end
					c = c + 1
				end
				eneg, emag, eov = cand, mag, ov
				i = c
			end
		end
		return {
			negative = negative, mantissa_end = mantissa_end, token_len = i - 1,
			cdigits = cdigits, fdigits = fdigits, lzeros = lzeros, tzeros = tzeros,
			coef = coef, cov = cov, eneg = eneg, emag = emag, eov = eov,
		}
	end

	local function scan_whole(s, int_grammar)
		local p = scan_prefix(s, int_grammar)
		if p == nil or p.token_len ~= #s then return nil end
		return p
	end

	local function is_zero(p) return p.lzeros == p.cdigits end

	-- appendDecimalZeros: initial * 10^count, or nil past limit.
	local function append_zeros(limit, initial, count)
		if W.cmp(initial, limit) > 0 then return nil end
		local max_before_mul = W.divmod_small(limit, 10)
		local v = initial
		for _ = 1, count do
			if W.cmp(v, max_before_mul) > 0 then return nil end
			v = mul_add(v, 10, 0)
		end
		return v
	end

	local function positive_exponent(p)
		if p.eneg and (p.eov or p.emag ~= 0) then return nil end
		if p.eov or p.emag > 38 then return nil end
		return p.emag
	end

	-- decimal_parse.parseInt over a whole `.int` token: negative, magnitude.
	local function parse_decimal_int(t, s)
		local lim = limits[t]
		local p = scan_whole(s, true)
		if p == nil then return nil end
		local zeros = positive_exponent(p)
		if zeros == nil then
			if not p.eneg and is_zero(p) then return false, big(0) end
			return nil
		end
		if p.cov then return nil end
		local mag = append_zeros((lim.signed and p.negative) and lim.neg or lim.max, p.coef, zeros)
		if mag == nil then return nil end
		if not lim.signed then
			if p.negative and not W.is_zero(mag) then return nil end
			return false, mag
		end
		return p.negative, mag
	end

	-- num.hasExplicitRadix / radixIntPrefixLen.
	local function has_explicit_radix(s)
		local n = #s
		if n == 0 then return false end
		local start = (byte(s, 1) == 45 or byte(s, 1) == 43) and 1 or 0
		if n - start < 2 or byte(s, start + 1) ~= 48 then return false end
		local r = byte(s, start + 2)
		return r == 98 or r == 66 or r == 111 or r == 79 or r == 120 or r == 88
	end
	local function radix_of(b)
		if b == 98 or b == 66 then return 2 end
		if b == 111 or b == 79 then return 8 end
		return 16
	end
	local function radix_int_prefix_len(s)
		if not has_explicit_radix(s) then return 0 end
		local n = #s
		local digits_start = ((byte(s, 1) == 45 or byte(s, 1) == 43) and 1 or 0) + 2 -- 0-based
		local radix = radix_of(byte(s, digits_start))
		local stop = digits_start
		local index = digits_start
		while index < n do
			local b = byte(s, index + 1)
			if b == 95 then
				if index == digits_start or index + 1 == n or not is_radix_digit(byte(s, index + 2), radix) then break end
			else
				if not is_radix_digit(b, radix) then break end
				stop = index + 1
			end
			index = index + 1
		end
		return stop == digits_start and 0 or stop
	end

	-- num.parseIntNoFmt over an explicit-radix token.
	local function parse_radix_int(t, s)
		local lim = limits[t]
		local n = #s
		if n == 0 then return nil end
		local i = 1
		local negative = byte(s, 1) == 45
		if byte(s, 1) == 45 or byte(s, 1) == 43 then
			i = 2
			if i > n then return nil end
		end
		local radix = 10
		if n - i + 1 >= 2 and byte(s, i) == 48 then
			local r = byte(s, i + 1)
			if r == 98 or r == 66 or r == 111 or r == 79 or r == 120 or r == 88 then
				radix = radix_of(r)
				i = i + 2
			end
		end
		local limit = (lim.signed and negative) and lim.neg or lim.max
		local max_before_mul, max_digit = W.divmod_small(limit, radix)
		local value = big(0)
		local saw_digit, prev_underscore = false, false
		for k = i, n do
			local b = byte(s, k)
			if b == 95 then
				if not saw_digit or prev_underscore then return nil end
				prev_underscore = true
			else
				local d = digit_value(b)
				if d == nil or d >= radix then return nil end
				local c = W.cmp(value, max_before_mul)
				if c > 0 or (c == 0 and d > max_digit) then return nil end
				value = mul_add(value, radix, d)
				saw_digit = true
				prev_underscore = false
			end
		end
		if not saw_digit or prev_underscore then return nil end
		if not lim.signed then
			if negative and not W.is_zero(value) then return nil end
			return false, value
		end
		return negative, value
	end

	-- num.intPrefixLen.
	function M.int_prefix_len(s)
		local r = radix_int_prefix_len(s)
		if r ~= 0 then return r end
		local p = scan_prefix(s, true)
		return p and p.token_len or 0
	end

	-- num.parseIntToken: negative, magnitude for type `t`, or nil.
	function M.int_token(t, s)
		if has_explicit_radix(s) then return parse_radix_int(t, s) end
		return parse_decimal_int(t, s)
	end

	-- decimal_parse.prefixLen(.dec).
	function M.dec_prefix_len(s)
		local p = scan_prefix(s, false)
		return p and p.token_len or 0
	end

	-- decimal_parse.parseScaledI128(bytes, 18): negative, magnitude, or nil.
	local I128_LIMITS = limits.i128
	function M.dec_token(s)
		local p = scan_whole(s, false)
		if p == nil then return nil end
		local limit = p.negative and I128_LIMITS.neg or I128_LIMITS.max
		local mag
		if is_zero(p) then
			mag = big(0)
		else
			if p.eov then return nil end
			local exponent = p.eneg and -p.emag or p.emag
			local scale = exponent - p.fdigits + 18
			if scale >= 0 then
				if scale > 38 or p.cov then return nil end
				mag = append_zeros(limit, p.coef, scale)
				if mag == nil then return nil end
			else
				local drop = -scale
				if drop > p.tzeros then return nil end
				local keep = p.cdigits - drop
				-- parseCoefficientPrefix: the first `keep` digits of the mantissa.
				local max_before_mul, max_digit = W.divmod_small(limit, 10)
				local value, consumed = big(0), 0
				local i = (byte(s, 1) == 45 or byte(s, 1) == 43) and 2 or 1
				while i <= p.mantissa_end and consumed < keep do
					local b = byte(s, i)
					if is_digit(b) then
						local d = b - 48
						local c = W.cmp(value, max_before_mul)
						if c > 0 or (c == 0 and d > max_digit) then return nil end
						value = mul_add(value, 10, d)
						consumed = consumed + 1
					end
					i = i + 1
				end
				mag = value
			end
		end
		return p.negative, mag
	end

	-- Floats -------------------------------------------------------------------

	local function lower_starts(s, at, word)
		return s:sub(at, at + #word - 1):lower() == word
	end

	-- num.floatMantissaExponentPrefixLen over s from position `at`.
	local function mantissa_exponent_len(s, at, radix, exp_char)
		local n = #s
		local index, digits, had_point = at, 0, false
		while index <= n do
			local b = byte(s, index)
			if is_radix_digit(b, radix) then
				digits = digits + 1
			elseif b == 95 and index > at and is_radix_digit(byte(s, index - 1), radix)
				and index + 1 <= n and is_radix_digit(byte(s, index + 1), radix) then
				-- separator
			elseif b == 46 and not had_point then
				had_point = true
			else
				break
			end
			index = index + 1
		end
		if digits == 0 then return 0 end
		local b = byte(s, index)
		if b ~= nil and bit.bor(b, 0x20) == exp_char then
			local c = index + 1
			local sb = byte(s, c)
			if sb == 45 or sb == 43 then c = c + 1 end
			if is_digit(byte(s, c)) then
				while c <= n do
					local x = byte(s, c)
					if not is_digit(x) and not (x == 95 and is_digit(byte(s, c - 1)) and c + 1 <= n and is_digit(byte(s, c + 1))) then
						break
					end
					c = c + 1
				end
				index = c
			end
		end
		return index - at
	end

	-- num.floatPrefixLen.
	function M.float_prefix_len(s)
		local n = #s
		local start = (n > 0 and (byte(s, 1) == 45 or byte(s, 1) == 43)) and 1 or 0
		local body = start + 1
		if n - start >= 2 and byte(s, body) == 48 and (byte(s, body + 1) == 120 or byte(s, body + 1) == 88) then
			local hex_len = mantissa_exponent_len(s, body + 2, 16, 112)
			if hex_len ~= 0 then return start + 2 + hex_len end
		end
		local decimal_len = mantissa_exponent_len(s, body, 10, 101)
		if decimal_len ~= 0 then return start + decimal_len end
		if lower_starts(s, body, "infinity") then return start + 8 end
		if lower_starts(s, body, "inf") then return start + 3 end
		if lower_starts(s, body, "nan") then return start + 3 end
		return 0
	end

	-- vendor/parse_float validUnderscores.
	local function valid_underscores(s, at, radix)
		local n = #s
		local i = at
		while i <= n do
			if byte(s, i) == 95 then
				if i == at or i == n then return false end
				if not is_radix_digit(byte(s, i - 1), radix) or not is_radix_digit(byte(s, i + 1), radix) then return false end
				i = i + 1
			end
			i = i + 1
		end
		return true
	end

	-- parse.parseNumber over s[at..] in `radix`, requiring the whole input:
	-- the digit string (separators removed), fractional digit count and the
	-- explicit exponent, or nil where parseFloat reports InvalidCharacter.
	local function parse_number(s, at, radix, exp_char)
		local n = #s
		local i = at
		local digits = {}
		local underscores = 0
		local function scan_digits()
			while i <= n do
				local b = byte(s, i)
				if b == 95 then
					underscores = underscores + 1
				elseif is_radix_digit(b, radix) and (radix == 16 or is_digit(b)) then
					digits[#digits + 1] = digit_value(b)
				else
					break
				end
				i = i + 1
			end
		end
		scan_digits()
		local frac = 0
		if byte(s, i) == 46 then
			i = i + 1
			local before = #digits
			scan_digits()
			frac = #digits - before
		end
		if #digits == 0 then return nil end
		local exponent = 0
		local b = byte(s, i)
		if b ~= nil and bit.bor(b, 0x20) == exp_char then
			i = i + 1
			local negative = false
			local sb = byte(s, i)
			if sb == 45 or sb == 43 then
				negative = sb == 45
				i = i + 1
			end
			if not is_digit(byte(s, i)) then return nil end
			while i <= n do
				local x = byte(s, i)
				if x == 95 then
					underscores = underscores + 1
				elseif is_digit(x) then
					if exponent < 0x10000000 then exponent = 10 * exponent + (x - 48) end
				else
					break
				end
				i = i + 1
			end
			if negative then exponent = -exponent end
		end
		if i <= n then return nil end
		if underscores > 0 and not valid_underscores(s, at, radix) then return nil end
		return digits, frac, exponent
	end

	-- Exact big integer from a digit list in `radix`.
	local function digits_value(digits, first, radix)
		local count = #digits - first + 1
		local limbs = math.max(LIMBS, floor(count * (radix == 16 and 4 or 3.33) / 16) + 2)
		local v = W.zero(limbs)
		for k = first, #digits do v = mul_add(v, radix, digits[k]) end
		return v
	end

	-- Exact powers of ten up to 10^22 (5^22 < 2^53), by repeated multiplication.
	local POW10 = { [0] = 1 }
	for k = 1, 22 do POW10[k] = POW10[k - 1] * 10 end

	local DECIMAL_HUGE, DECIMAL_TINY = 311, -330 -- powers of ten beyond any float
	local BINARY_HUGE, BINARY_TINY = 1100, -1200

	-- parseFloatToken's value: the token's float, or nil (InvalidCharacter, or
	-- a finite token that overflows to infinity).
	function M.float_token(s, is_f32)
		local n = #s
		if n == 0 then return nil end
		local i = 1
		local negative = byte(s, 1) == 45
		if byte(s, 1) == 45 or byte(s, 1) == 43 then i = 2 end
		if i > n then return nil end
		local hex = n - i + 1 >= 2 and byte(s, i) == 48 and (byte(s, i + 1) == 120 or byte(s, i + 1) == 88)
		local digits, frac, exponent
		if hex then
			digits, frac, exponent = parse_number(s, i + 2, 16, 112)
		else
			digits, frac, exponent = parse_number(s, i, 10, 101)
		end
		if digits == nil then
			local rest = s:sub(i):lower()
			if rest == "inf" or rest == "infinity" then return negative and -math.huge or math.huge end
			if rest == "nan" then return 0 / 0 end
			return nil
		end
		local first = 1
		while first <= #digits and digits[first] == 0 do first = first + 1 end
		if first > #digits then return negative and -0.0 or 0.0 end
		local count = #digits - first + 1
		local value
		if hex then
			local e2 = exponent - 4 * frac
			local mag = digits_value(digits, first, 16)
			local top = W.bit_length(mag) + e2
			if top > BINARY_HUGE then return nil end
			if top < BINARY_TINY then return negative and -0.0 or 0.0 end
			value = F.round_scaled(mag, e2, 0, is_f32)
		else
			local e10 = exponent - frac
			-- Clinger's fast path (parseFloat's convertFast): an exact integer
			-- significand and an exact power of ten, so one IEEE operation is
			-- the correctly rounded result. For F32 both operands are exact
			-- binary32 values and the double result rounds once more to binary32,
			-- which is exact by the 2p+2 bound (53 >= 2*24+2).
			local fast_digits, fast_exp = 15, 22
			if is_f32 then fast_digits, fast_exp = 7, 10 end
			if count <= fast_digits and e10 >= -fast_exp and e10 <= fast_exp then
				local m = 0
				for k = first, #digits do m = m * 10 + digits[k] end
				if not is_f32 or m <= 16777216 then
					local v = e10 >= 0 and m * POW10[e10] or m / POW10[-e10]
					if is_f32 then v = F.f32(v) end
					return negative and -v or v
				end
			end
			if count + e10 - 1 > DECIMAL_HUGE then return nil end
			if count + e10 < DECIMAL_TINY then return negative and -0.0 or 0.0 end
			value = F.round_scaled(digits_value(digits, first, 10), 0, e10, is_f32)
		end
		if value == math.huge then return nil end
		return negative and -value or value
	end

	return M
end
