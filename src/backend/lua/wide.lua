-- Exact fixed-width unsigned integers for the roc_luajit runtime.
-- A value is a Lua array of 16-bit limbs, least significant first, all plain
-- Lua numbers. Every limb product (< 2^32) and every column sum stays far
-- below 2^53, so all arithmetic is exact without FFI. Correctness first;
-- representation and speed are revisited after conformance (the owner, 2026-09-30).
local W = {}

local BASE = 65536
local floor = math.floor

-- Zero value with n limbs. The common widths (128 and 256 bits) are table
-- constructors, which compile to one allocation of the final size.
function W.zero(n)
	if n == 8 then return { 0, 0, 0, 0, 0, 0, 0, 0 } end
	if n == 16 then return { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } end
	local r = {}
	for i = 1, n do r[i] = 0 end
	return r
end

-- Value with n limbs from a non-negative Lua integer below 2^53.
function W.from_small(v, n)
	local r = W.zero(n)
	local i = 1
	while v > 0 do
		r[i] = v % BASE
		v = floor(v / BASE)
		i = i + 1
	end
	return r
end

function W.copy(a)
	local r = {}
	for i = 1, #a do r[i] = a[i] end
	return r
end

-- Resize to n limbs (truncating or zero-extending).
function W.resize(a, n)
	if n == 8 then
		return { a[1] or 0, a[2] or 0, a[3] or 0, a[4] or 0, a[5] or 0, a[6] or 0, a[7] or 0, a[8] or 0 }
	end
	local r = {}
	for i = 1, n do r[i] = a[i] or 0 end
	return r
end

function W.is_zero(a)
	for i = 1, #a do if a[i] ~= 0 then return false end end
	return true
end

-- Unsigned comparison: -1, 0, 1. Operands have equal limb counts.
function W.cmp(a, b)
	for i = #a, 1, -1 do
		if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
	end
	return 0
end

-- a + b modulo BASE^n, plus the carry out (0 or 1).
function W.add(a, b)
	local r, carry = {}, 0
	for i = 1, #a do
		local s = a[i] + b[i] + carry
		if s >= BASE then r[i], carry = s - BASE, 1 else r[i], carry = s, 0 end
	end
	return r, carry
end

-- a - b modulo BASE^n, plus the borrow out (0 or 1).
function W.sub(a, b)
	local r, borrow = {}, 0
	for i = 1, #a do
		local s = a[i] - b[i] - borrow
		if s < 0 then r[i], borrow = s + BASE, 1 else r[i], borrow = s, 0 end
	end
	return r, borrow
end

-- Two's-complement negation modulo BASE^n.
function W.neg(a)
	local r, borrow = {}, 0
	for i = 1, #a do
		local s = -a[i] - borrow
		if s < 0 then r[i], borrow = s + BASE, 1 else r[i], borrow = s, 0 end
	end
	return r
end

-- Full product: #a + #b limbs, exact.
function W.mul_full(a, b)
	local n, m = #a, #b
	local r = W.zero(n + m)
	for i = 1, n do
		local ai = a[i]
		if ai ~= 0 then
			local carry = 0
			for j = 1, m do
				local t = r[i + j - 1] + ai * b[j] + carry
				carry = floor(t / BASE)
				r[i + j - 1] = t - carry * BASE
			end
			local k = i + m
			while carry ~= 0 do
				local t = r[k] + carry
				carry = floor(t / BASE)
				r[k] = t - carry * BASE
				k = k + 1
			end
		end
	end
	return r
end

-- Logical right shift by s bits (0 <= s), keeping the limb count.
function W.shr(a, s)
	local n = #a
	local limbs, bits = floor(s / 16), s % 16
	local r = {}
	for i = 1, n do
		local lo = a[i + limbs] or 0
		local hi = a[i + limbs + 1] or 0
		if bits == 0 then
			r[i] = lo
		else
			r[i] = floor(lo / 2 ^ bits) + (hi % 2 ^ bits) * 2 ^ (16 - bits)
		end
	end
	return r
end

-- Left shift by s bits modulo BASE^n.
function W.shl(a, s)
	local n = #a
	local limbs, bits = floor(s / 16), s % 16
	local r = {}
	for i = 1, n do
		local lo = a[i - limbs] or 0
		local below = a[i - limbs - 1] or 0
		if bits == 0 then
			r[i] = lo
		else
			r[i] = (lo * 2 ^ bits) % BASE + floor(below / 2 ^ (16 - bits))
		end
	end
	return r
end

function W.bit_length(a)
	for i = #a, 1, -1 do
		local v = a[i]
		if v ~= 0 then
			local b = 0
			while v > 0 do v = floor(v / 2); b = b + 1 end
			return (i - 1) * 16 + b
		end
	end
	return 0
end

-- Unsigned division: quotient and remainder, both with #a limbs; b must be
-- non-zero and may have fewer limbs than a. Knuth's Algorithm D (TAOCP 4.3.1)
-- in base 2^16: every partial product and estimate stays below 2^53, so
-- doubles carry it exactly. With quotient_only the remainder is not built and
-- nil is returned in its place.
function W.divmod(a, b, quotient_only)
	local n = #a
	local q = W.zero(n)
	local r = not quotient_only and W.zero(n) or nil
	local m = #b
	while m > 0 and b[m] == 0 do m = m - 1 end
	local la = n
	while la > 0 and a[la] == 0 do la = la - 1 end
	if la < m then
		if r then
			for i = 1, la do r[i] = a[i] end
		end
		return q, r
	end
	if m == 1 then
		local d, rem = b[1], 0
		for i = la, 1, -1 do
			local cur = rem * BASE + a[i]
			local qi = floor(cur / d)
			q[i] = qi
			rem = cur - qi * d
		end
		if r then r[1] = rem end
		return q, r
	end
	-- Normalize so the divisor's top limb has its high bit set.
	local s, top = 0, b[m]
	while top < 32768 do
		top = top * 2
		s = s + 1
	end
	local scale = 2 ^ s
	local v, u = {}, {}
	local carry = 0
	for i = 1, m do
		local x = b[i] * scale + carry
		v[i] = x % BASE
		carry = floor(x / BASE)
	end
	carry = 0
	for i = 1, la do
		local x = a[i] * scale + carry
		u[i] = x % BASE
		carry = floor(x / BASE)
	end
	u[la + 1] = carry
	local vtop, vnext = v[m], v[m - 1]
	for j = la - m, 0, -1 do
		local num = u[j + m + 1] * BASE + u[j + m]
		local qhat = floor(num / vtop)
		local rhat = num - qhat * vtop
		while qhat >= BASE or qhat * vnext > rhat * BASE + u[j + m - 1] do
			qhat = qhat - 1
			rhat = rhat + vtop
			if rhat >= BASE then break end
		end
		-- u[j+1 .. j+m+1] -= qhat * v
		local borrow, mc = 0, 0
		for i = 1, m do
			local p = qhat * v[i] + mc
			mc = floor(p / BASE)
			local t = u[j + i] - (p % BASE) - borrow
			if t < 0 then
				u[j + i] = t + BASE
				borrow = 1
			else
				u[j + i] = t
				borrow = 0
			end
		end
		local t = u[j + m + 1] - mc - borrow
		if t < 0 then
			-- qhat was one too large: add the divisor back.
			qhat = qhat - 1
			local c = 0
			for i = 1, m do
				local x = u[j + i] + v[i] + c
				if x >= BASE then
					u[j + i] = x - BASE
					c = 1
				else
					u[j + i] = x
					c = 0
				end
			end
			t = t + c
		end
		u[j + m + 1] = t
		q[j + 1] = qhat
	end
	if not r then return q end
	-- Remainder: u[1..m] shifted back down.
	for i = 1, m do
		local hi = u[i + 1] or 0
		if i == m then hi = 0 end
		r[i] = floor(u[i] / scale) + (hi % scale) * (BASE / scale)
	end
	return q, r
end

-- Quotient and remainder by a small divisor (< 2^36), exact: each step's
-- dividend rem * BASE + limb is below 2^52, and its quotient digit is below
-- BASE, so the double quotient is within 2^-37 of the true one, closer than
-- the 1/d gap to the next integer.
function W.divmod_small(a, d)
	local q, rem = {}, 0
	for i = #a, 1, -1 do
		local cur = rem * BASE + a[i]
		q[i] = floor(cur / d)
		rem = cur - q[i] * d
	end
	return q, rem
end

-- divmod_small writing the quotient over a itself, for a caller's own
-- temporary; returns the remainder.
function W.div_small_in_place(a, d)
	local rem = 0
	for i = #a, 1, -1 do
		local cur = rem * BASE + a[i]
		local qi = floor(cur / d)
		a[i] = qi
		rem = cur - qi * d
	end
	return rem
end

-- Unsigned decimal digits.
function W.to_decimal(a)
	if W.is_zero(a) then return "0" end
	local parts, x = {}, a
	while not W.is_zero(x) do
		local rem
		x, rem = W.divmod_small(x, 10000)
		parts[#parts + 1] = rem
	end
	local out = { tostring(parts[#parts]) }
	for i = #parts - 1, 1, -1 do out[#out + 1] = string.format("%04d", parts[i]) end
	return (table.concat(out))
end

-- Parse unsigned decimal digits into n limbs (modulo BASE^n): r = r * 10 +
-- digit in place, one limb pass per digit. Module setup parses its constants
-- this way, so it sits on every program's startup path.
function W.from_decimal(s, n)
	local r = W.zero(n)
	for i = 1, #s do
		local carry = s:byte(i) - 48
		for j = 1, n do
			local t = r[j] * 10 + carry
			carry = floor(t / BASE)
			r[j] = t - carry * BASE
		end
	end
	return r
end

return W
