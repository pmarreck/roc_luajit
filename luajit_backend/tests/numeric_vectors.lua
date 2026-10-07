-- Replays reference vectors (from luajit-numeric-vectors, built on upstream's
-- Zig builtins and native Zig integer arithmetic) against the runtime helpers
-- the emitter calls. Usage: luajit numeric_vectors.lua VECTORS
local ffi = require("ffi")
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = here .. "/../../src/backend/lua/"
local W = dofile(src .. "wide.lua")
local I = dofile(src .. "int128.lua")(W)
local rt = assert(loadfile(src .. "runtime.lua"))(W, I, dofile(src .. "list.lua"), dofile(src .. "float.lua"), dofile(src .. "sort.lua"), dofile(src .. "numparse.lua"), dofile(src .. "fmath.lua"), dofile(src .. "simd.lua"), dofile(src .. "crypto.lua"))

-- Operand parsing and printing per representation (design.md).
local function parse_int64(s, ctype)
	local negative = s:sub(1, 1) == "-"
	local v = ffi.new(ctype, 0)
	for i = negative and 2 or 1, #s do v = v * 10 + (s:byte(i) - 48) end
	if negative then v = -v end
	return v
end
local function parse_signed_wide(s)
	if s:sub(1, 1) == "-" then return W.neg(W.from_decimal(s:sub(2), 8)) end
	return W.from_decimal(s, 8)
end
-- I64/U64 operands (design.md) are int64_t/uint64_t cdata, or with
-- ROC_LUAJIT_INT64_REPR=mixed Lua numbers whenever -2^53 < v < 2^53, as
-- emitted code passes them. Either way every 64-bit result must be a valid
-- representation of its type, or it shows as "badrepr:".
local mixed_mode = os.getenv("ROC_LUAJIT_INT64_REPR") == "mixed"
local SAFE = 2 ^ 53
local function parse64(s, ctype)
	local v = parse_int64(s, ctype)
	if mixed_mode and v > -SAFE and v < SAFE then return tonumber(v) end
	return v
end
local function show64(ctype, show)
	return function(x)
		if type(x) == "number" then
			if x ~= math.floor(x) or x <= -SAFE or x >= SAFE or (ctype == "uint64_t" and x < 0) then
				return "badrepr:" .. tostring(x)
			end
		elseif not ffi.istype(ctype, x) then
			return "badrepr:" .. tostring(x)
		end
		return show(x)
	end
end
local reprs = {
	i64 = { parse = function(s) return parse64(s, "int64_t") end, show = show64("int64_t", function(x) return rt.str(rt.i64_to_str(x)) end) },
	u64 = { parse = function(s) return parse64(s, "uint64_t") end, show = show64("uint64_t", function(x) return rt.str(rt.u64_to_str(x)) end) },
	i128 = { parse = parse_signed_wide, show = I.i128_to_str },
	u128 = { parse = function(s) return W.from_decimal(s, 8) end, show = I.u128_to_str },
	dec = { parse = parse_signed_wide, show = I.i128_to_str }, -- raw scaled bits
}
for _, t in ipairs({ "u8", "i8", "u16", "i16", "u32", "i32" }) do
	local to_str = rt[t .. "_to_str"]
	reprs[t] = { parse = tonumber, show = function(x) return rt.str(to_str(x)) end }
end
-- Floats travel as bit patterns (NaN normalized by to_bits).
reprs.f64 = {
	parse = function(s) return rt.f64_from_bits(parse_int64(s, "uint64_t")) end,
	show = function(x) return reprs.u64.show(rt.f64_bits(x)) end,
}
reprs.f32 = {
	parse = function(s) return rt.f32_from_bits(tonumber(s)) end,
	show = function(x) return tostring(rt.f32_bits(x)) end,
}

-- Crash messages passed to checked helpers; `crash:zero`/`crash:overflow`
-- vectors assert which of the two the helper raised.
local ZERO, OVERFLOW = "zero", "overflow"

local function family(t)
	return {
		["div_trunc_" .. t] = function(a, b) return rt["div_trunc_" .. t](a, b) end,
		["div_trunc_checked_" .. t] = function(a, b) return rt["div_trunc_checked_" .. t](a, b, ZERO, OVERFLOW) end,
		["rem_" .. t] = function(a, b) return rt["rem_" .. t](a, b) end,
		["rem_checked_" .. t] = function(a, b) return rt["rem_checked_" .. t](a, b, ZERO) end,
		["mod_" .. t] = function(a, b) return rt["mod_" .. t](a, b) end,
		["mod_checked_" .. t] = function(a, b) return rt["mod_checked_" .. t](a, b, ZERO) end,
		["neg_wrap_" .. t] = function(a) return rt["neg_wrap_" .. t](a) end,
		["neg_checked_" .. t] = function(a) return rt["neg_checked_" .. t](a, OVERFLOW) end,
		["abs_wrap_" .. t] = function(a) return rt["abs_wrap_" .. t](a) end,
		["abs_checked_" .. t] = function(a) return rt["abs_checked_" .. t](a, OVERFLOW) end,
	}
end

-- op -> { type, function }
local ops = {}
local function add(t, f, name) ops[name] = { t = t, f = f } end
for _, t in ipairs({ "u8", "i8", "u16", "i16", "u32", "i32", "u64", "i64", "u128", "i128" }) do
	for name, f in pairs(family(t)) do add(t, f, name) end
	-- abs_diff returns the unsigned type of the same width.
	local unsigned = t:gsub("^i", "u")
	ops["abs_diff_" .. t] = { t = t, show_as = unsigned, f = function(a, b) return rt["abs_diff_" .. t](a, b) end }
end
add("i128", function(a, b) return I.add_checked_i128(a, b, "m") end, "add_i128")
add("i128", function(a, b) return I.sub_checked_i128(a, b, "m") end, "sub_i128")
add("i128", function(a, b) return I.mul_checked_i128(a, b, "m") end, "mul_i128")
add("i128", function(a, b) return I.mul_wrap(a, b) end, "mulwrap_i128")
add("u128", function(a, b) return I.add_checked_u128(a, b, "m") end, "add_u128")
add("u128", function(a, b) return I.sub_checked_u128(a, b, "m") end, "sub_u128")
add("u128", function(a, b) return I.mul_checked_u128(a, b, "m") end, "mul_u128")
add("dec", function(a, b) return rt.dec_mul(a, b, "m") end, "dec_mul")
add("dec", function(a, b) return rt.dec_div(a, b) end, "dec_div")
add("dec", function(a, b) return rt.dec_div_trunc(a, b) end, "dec_div_trunc")
add("dec", function(a, b) return rt.dec_rem(a, b) end, "dec_rem")
add("dec", function(a, b) return rt.dec_mod(a, b) end, "dec_mod")
add("dec", function(a) return rt.neg_wrap_dec(a) end, "neg_wrap_dec")
add("dec", function(a) return rt.abs_wrap_dec(a) end, "abs_wrap_dec")
add("dec", function(a) return rt.abs_checked_dec(a, "m") end, "abs_checked_dec")
-- Ops whose result is not a value of the operand type.
local special = {
	f64str = function(a) return rt.f64_to_str(rt.f64_from_bits(a)) end,
	f32str = function(a) return rt.f32_to_str(rt.f32_from_bits(a)) end,
	cmp_i128 = function(a, b) return tostring(rt.cmp_i128(a, b)) end,
	cmp_u128 = function(a, b) return tostring(rt.cmp_u128(a, b)) end,
	dec_to_str = function(a) return rt.dec_to_str(a) end,
	i128_to_str = function(a) return rt.i128_to_str(a) end,
}
local special_type = { f64str = "u64", f32str = "u32", cmp_i128 = "i128", cmp_u128 = "u128", dec_to_str = "dec", i128_to_str = "i128" }

-- Conversion vectors: op names carry their source and destination kinds.
local function conversion(op)
	local isrc, ifl = op:match("^itof_(%w+)_(f%d+)$")
	if isrc then return isrc, ifl, function(a) return rt.cvt_int_float(a, isrc, ifl == "f32") end end
	local ffl, fdst = op:match("^ftoi_(f%d+)_(%w+)$")
	if ffl then return ffl, fdst, function(a) return rt.cvt_float_int(a, ffl == "f32", fdst) end end
	ffl, fdst = op:match("^ftoitry_(f%d+)_(%w+)$")
	if ffl then return ffl, fdst, function(a) return rt.cvt_float_int_try(a, ffl == "f32", fdst) end, true end
	if op == "f64tof32" then return "f64", "f32", rt.cvt_f64_f32 end
	if op == "f64tof32try" then return "f64", "f32", rt.cvt_f64_f32_try, true end
	if op == "dectof64" then return "dec", "f64", function(a) return rt.cvt_dec_float(a, false) end end
	if op == "dectof32" then return "dec", "f32", function(a) return rt.cvt_dec_float(a, true) end end
	local arith = op:match("^f32(%l+)$")
	if arith then
		local fns = {
			add = function(a, b) return rt.f32(a + b) end,
			sub = function(a, b) return rt.f32(a - b) end,
			mul = function(a, b) return rt.f32(a * b) end,
			div = function(a, b) return rt.f32(a / b) end,
			sqrt = function(a) return rt.f32(math.sqrt(a)) end,
		}
		if fns[arith] then return "f32", "f32", fns[arith] end
	end
	local sop, st = op:match("^(shr_zf)_(%w+)$")
	if not sop then sop, st = op:match("^(sh[lr])_(%w+)$") end
	if sop then return st, st, function(a, b) return rt[sop .. "_" .. st](a, b) end, false, true end
	local bop, bt = op:match("^(b[a-z]+)_(%w+)$")
	if bop then return bt, bt, function(a, b) return rt[bop .. "_" .. bt](a, b) end end
	local cop, ct = op:match("^(popcount)_(%w+)$")
	if not cop then cop, ct = op:match("^(c[lt]z)_(%w+)$") end
	if cop then return ct, "u8", function(a) return rt[cop .. "_" .. ct](a) end end
	local oop, ot = op:match("^([a-z]+_overflows)_(%w+)$")
	if oop then return ot, "u8", function(a, b) return rt[oop .. "_" .. ot](a, b) and 1 or 0 end end
	local src, dst = op:match("^cvt_(%w+)_(%w+)$")
	if src then return src, dst, function(a) return rt.cvt_int(a, src, dst) end end
	src, dst = op:match("^cvttry_(%w+)_(%w+)$")
	if src then return src, dst, function(a) return rt.cvt_int_try(a, src, dst) end, true end
	src = op:match("^cvtdec_(%w+)$")
	if src then return src, "dec", function(a) return rt.cvt_int_dec(a, src) end end
	src = op:match("^cvtdectry_(%w+)$")
	if src then return src, "dec", function(a) return rt.cvt_int_dec_try(a, src) end, true end
	dst = op:match("^cvtfromdec_(%w+)$")
	if dst then return "dec", dst, function(a) return rt.cvt_dec_int(a, dst) end end
	dst = op:match("^cvtfromdectry_(%w+)$")
	if dst then return "dec", dst, function(a) return rt.cvt_dec_int_try(a, dst) end, true end
end


-- Fluxsort vectors (`sort` / `sortout`): the same element ids, values and
-- comparator modes as emitSortVectors, replayed through sort.lua.
local SORT = dofile(src .. "sort.lua")
local FM = dofile(src .. "fmath.lua")(dofile(src .. "float.lua")(W))
local SV = rt.V
local bit = require("bit")
-- 32 hex digits (most significant first) as 8 little-endian 16-bit limbs.
local function hex_limbs(h)
	local r = {}
	for i = 1, 8 do r[i] = tonumber(h:sub(33 - 4 * i, 36 - 4 * i), 16) end
	return r
end
-- A lane scalar in its Roc representation from the low bits of a value.
local function natural(K, limbs)
	if K.w == 64 then
		local u = 0ULL
		for i = 4, 1, -1 do u = u * 65536 + limbs[i] end
		if K.s then u = ffi.cast("int64_t", u) end
		if mixed_mode and u > -SAFE and u < SAFE then return tonumber(u) end
		return u
	end
	local v = limbs[1] + (K.w == 32 and limbs[2] * 65536 or 0)
	v = v % 2 ^ K.w
	if K.s and v >= 2 ^ (K.w - 1) then v = v - 2 ^ K.w end
	return v
end
local function hex64(x) return ("0"):rep(16) .. bit.tohex(x, 16) end
-- Any SIMD result (vector, limbs, number or 64-bit cdata) as 32 hex digits;
-- scalars are their bit pattern at the Roc result width.
local function limbs_hex(x, sop, A)
	if type(x) == "cdata" and ffi.istype(SV.V, x) then x = SV.to_u128_bits(x) end
	if type(x) == "table" then
		local parts = {}
		for i = 8, 1, -1 do parts[#parts + 1] = ("%04x"):format(x[i]) end
		return table.concat(parts)
	end
	if type(x) == "cdata" then return hex64(x) end
	local width = A.w
	if sop == "bitmask" then width = 16 end
	if sop:match("^sum_lanes") then width = A.w <= 16 and 32 or 64 end
	if width == 64 then return hex64(0LL + x) end
	if x < 0 then x = x + 2 ^ width end
	return ("%032x"):format(x)
end
local HASH = 1000000007
local function sort_values(kind, n, seed)
	local vals, x = {}, seed % 2147483646 + 1
	for i = 0, n - 1 do
		local v
		if kind == 0 then v = i
		elseif kind == 1 then v = n - i
		elseif kind == 2 then
			x = x * 48271 % 2147483647
			v = x % (n + 1)
		elseif kind == 3 then v = i % 37
		else v = (i % 50 == 0) and n - i or i end
		vals[i] = v
	end
	return vals
end
local function sort_case(spec)
	local kind, mode, n, seed = spec:match("^(%d+),(%d+),(%d+),(%d+)$")
	kind, mode, n, seed = tonumber(kind), tonumber(mode), tonumber(n), tonumber(seed)
	local vals = sort_values(kind, n, seed)
	local calls, trace = 0, 0
	local function after(a, b)
		trace = (trace * 31 + a * 1009 + b + 1) % HASH
		calls = calls + 1
		if mode == 0 then return vals[a] > vals[b]
		elseif mode == 1 then return vals[a] % 7 > vals[b] % 7
		elseif mode == 2 then return ((a * 7919 + b * 104729 + seed * 15485863 + calls * 31) % 1000003) % 3 == 0
		else return vals[b] > vals[a] end
	end
	local mem = {}
	for i = 1, n do mem[i] = i - 1 end
	SORT.fluxsort(mem, n, after)
	local out = 0
	for i = 1, n do out = (out * 31 + mem[i] + 1) % HASH end
	return calls, trace, out
end


-- Numeric parsing vectors (`pint_T`, `pintp_T`, `pdec`, `pdecp`, `pflt_F`,
-- `pfltp_F`): the input is hex-encoded ("-" for empty). Prefix parses run on
-- both the Str and the List(U8) entry points, and `rest` must be the
-- unconsumed remainder (empty on error).
local parse_ops = {}
for _, t in ipairs({ "u8", "i8", "u16", "i16", "u32", "i32", "u64", "i64", "u128", "i128" }) do
	parse_ops["pint_" .. t] = { kind = "int", t = t }
	parse_ops["pintp_" .. t] = { kind = "int", t = t, prefix = true }
end
parse_ops.pdec = { kind = "dec", t = "dec" }
parse_ops.pdecp = { kind = "dec", t = "dec", prefix = true }
for _, t in ipairs({ "f32", "f64" }) do
	parse_ops["pflt_" .. t] = { kind = "float", t = t }
	parse_ops["pfltp_" .. t] = { kind = "float", t = t, prefix = true }
end
local NP = dofile(src .. "numparse.lua")(W, dofile(src .. "float.lua")(W))
local prefix_len = { int = NP.int_prefix_len, dec = NP.dec_prefix_len, float = NP.float_prefix_len }
local function unhex(h)
	if h == "-" then return "" end
	return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end))
end
local function list_of(s)
	local a = {}
	for i = 1, #s do a[i] = s:byte(i) end
	return rt.L.literal(1, a, #s)
end
local function list_string(l)
	local out = {}
	for i = 1, l[3] do out[i] = string.char(l[1][l[2] + i]) end
	return table.concat(out)
end
local function parse_case(spec, h)
	local s = unhex(h)
	local show = reprs[spec.t].show
	if not spec.prefix then
		local r = rt.num_from_str(s, spec.kind, spec.t, rt.ZST)
		return r[1] == 1 and ("1:" .. show(r[2])) or "0"
	end
	local r = rt.num_from_prefix(s, spec.kind, spec.t, false)
	local lr = rt.num_from_prefix(list_of(s), spec.kind, spec.t, true)
	local consumed = r[1] == 0 and #s - #r[2] or prefix_len[spec.kind](s)
	local want_rest = r[1] == 0 and s:sub(consumed + 1) or ""
	if r[2] ~= want_rest then return "bad str rest " .. r[2] end
	if lr[1] ~= r[1] or list_string(lr[2]) ~= want_rest or show(lr[3]) ~= show(r[3]) then return "list path differs" end
	return ("%d:%d:%s"):format(consumed, r[1], show(r[3]))
end

local total, failures, per_op = 0, 0, {}
local file = assert(io.open(assert(arg[1], "usage: numeric_vectors.lua VECTORS"), "r"))
for text in file:lines() do
	local op, sa, sb, want = text:match("^(%S+) (%S+) (%S+) (.+)$")
	assert(op, "malformed vector: " .. text)
	local cname = op:match("^decconst_(.+)$")
	local dname = op:match("^decm_(.+)$")
	if cname or dname then
		local got
		if cname then
			got = I.i128_to_str(I["DEC_" .. cname:upper()])
		else
			local ok, r = pcall(I["dec_" .. dname], parse_signed_wide(sa), parse_signed_wide(sb))
			if ok then
				got = I.i128_to_str(r)
			elseif type(r) == "table" and r.roc_crash then
				got = "crash:" .. r.message
			else
				error(r, 0)
			end
		end
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s, %s): got %s, want %s\n"):format(op, sa, sb, got, want)) end
		end
		goto continue
	end
	local calg, cop = op:match("^c(%w+)_(%a+)$")
	if calg == "sha" or calg == "b3" then
		local name = (calg == "sha" and "crypto_sha256_" or "crypto_blake3_")
		local got
		if cop == "hash" then
			got = rt[name .. "hash_bytes"](list_of(unhex(sa)))
		elseif cop == "empty" then
			got = rt[name .. "hasher_empty"]()
		elseif cop == "write" then
			got = rt[name .. "hasher_write"](list_of(unhex(sa)), list_of(unhex(sb)))
		else
			got = rt[name .. "hasher_finish"](list_of(unhex(sa)))
		end
		got = list_string(got)
		got = #got == 0 and "-" or (got:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s, %s): got %s, want %s\n"):format(op, sa:sub(1, 80), sb:sub(1, 80), got:sub(1, 300), want:sub(1, 300))) end
		end
		goto continue
	end
	local sop, sak, srk = op:match("^simd_(.+)_([ui]%d+x%d+)_([ui]%d+x%d+)$")
	if sop then
		local A, R = SV[sak], SV[srk]
		local ha, hb = sa:match("^(%x+):(%x+)$")
		local a, b = SV.from_u128_bits(hex_limbs(ha)), SV.from_u128_bits(hex_limbs(hb))
		local bl = hex_limbs(hb)
		local got
		if sop == "splat" then
			got = SV.splat(R, natural(A, hex_limbs(ha)))
		elseif sop == "get_lane_unchecked" then
			got = SV.get_lane(A, a, 0ULL + bl[1])
		elseif sop == "with_lane_unchecked" then
			got = SV.with_lane(A, a, 0ULL + bl[1], natural(A, W.from_decimal(sb, 8)))
		elseif sop == "to_u128_bits" then
			got = SV.to_u128_bits(a)
		elseif sop == "from_u128_bits" then
			got = SV.from_u128_bits(hex_limbs(ha))
		elseif sop == "shl_wrap" or sop == "shr_wrap" or sop == "shr_zf_wrap" or sop == "shr_rounded" then
			got = SV[sop](A, a, bl[1] % 256)
		elseif sop == "and" or sop == "or" or sop == "xor" then
			got = SV["b" .. sop](a, b)
		elseif sop == "not" then
			got = SV.bnot(a)
		elseif sop == "bit_select" then
			got = SV.bit_select(a, b, SV.from_u128_bits(W.from_decimal(sb, 8)))
		elseif sop == "concat_shift_bytes" then
			got = SV.concat_shift_bytes(a, b, tonumber(sb))
		elseif sop == "clmul_lo" or sop == "clmul_hi" then
			got = SV[sop](a, b)
		elseif sop:match("^mul_wide") or sop:match("^widen") or sop == "pairwise_add_widen" or sop:match("^narrow") then
			got = SV[sop](A, R, a, b)
		elseif sop == "sum_lanes_wrap" then
			got = SV.sum_lanes(A, a)
		else
			got = SV[sop](A, a, b)
		end
		got = limbs_hex(got, sop, A)
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s, %s): got %s, want %s\n"):format(op, sa, sb, got, want)) end
		end
		goto continue
	end
	local fw, fname = op:match("^fm(%d+)_(.+)$")
	if fw or op == "fmconst_three_pio2_1t" then
		local got
		if op == "fmconst_three_pio2_1t" then
			got = reprs.u64.show(rt.f64_to_bits(FM.THREE_PIO2_1T))
		elseif fw == "64" then
			got = reprs.u64.show(rt.f64_to_bits(FM[fname .. "_f64"](rt.f64_from_bits(reprs.u64.parse(sa)), rt.f64_from_bits(reprs.u64.parse(sb)))))
		else
			got = tostring(tonumber(rt.f32_to_bits(FM[fname .. "_f32"](rt.f32_from_bits(tonumber(sa)), rt.f32_from_bits(tonumber(sb))))))
		end
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s, %s): got %s, want %s\n"):format(op, sa, sb, got, want)) end
		end
		goto continue
	end
	local hd, hw = op:match("^hwint_(%d+)_(%d+)$")
	if hd or op == "hfinish" or op:match("^hwwide_") or op == "hwf32" or op == "hwf64" or op == "hwstr" then
		local seed = reprs.u64.parse(sa)
		local r
		if hd then
			r = rt.hash_write_int(seed, tonumber(hd), reprs.u64.parse(sb), tonumber(hw))
		elseif op == "hfinish" then
			r = rt.hash_finish(seed)
		elseif op == "hwf32" then
			r = rt.hash_write_f32(seed, rt.f32_from_bits(tonumber(sb)))
		elseif op == "hwf64" then
			r = rt.hash_write_f64(seed, rt.f64_from_bits(reprs.u64.parse(sb)))
		elseif op == "hwstr" then
			r = rt.hash_write_str(seed, unhex(sb))
		else
			r = rt.hash_write_wide(seed, tonumber(op:match("^hwwide_(%d+)$")), W.from_decimal(sb, 8))
		end
		local got = reprs.u64.show(r)
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s, %s): got %s, want %s\n"):format(op, sa, sb, got, want)) end
		end
		goto continue
	end
	if op == "utf8" or op == "utf8lossy" then
		local l = list_of(unhex(sa))
		local got
		if op == "utf8" then
			got = rt.str_from_utf8(l, function() return "ok" end, function(index, problem)
				return "err:" .. reprs.u64.show(index) .. ":" .. problem
			end)
		else
			local s = rt.str_from_utf8_lossy(l)
			got = #s == 0 and "-" or (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
		end
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s): got %s, want %s\n"):format(op, sa, got, want)) end
		end
		goto continue
	end
	if parse_ops[op] then
		local got = parse_case(parse_ops[op], sa)
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s): got %s, want %s\n"):format(op, sa, got, want)) end
		end
		goto continue
	end
	if op == "sort" or op == "sortout" then
		local calls, trace, out = sort_case(sa)
		local got = op == "sort" and ("%d:%d:%d"):format(calls, trace, out) or tostring(out)
		total = total + 1
		per_op[op] = (per_op[op] or 0) + 1
		if got ~= want then
			failures = failures + 1
			if failures <= 20 then io.stderr:write(("FAIL %s(%s): got %s, want %s\n"):format(op, sa, got, want)) end
		end
		goto continue
	end
	local entry, t = ops[op], nil
	local csrc, cdst, cf, ctry, camount = conversion(op)
	if cf then
		entry, t = { f = cf, show_as = cdst, try = ctry, amount = camount }, csrc
	elseif entry then
		t = entry.t
	else
		t = assert(special_type[op], "unknown op in vectors: " .. op)
	end
	local repr = reprs[t]
	local a, b = repr.parse(sa), (entry and entry.amount) and tonumber(sb) or repr.parse(sb)
	local ok, got = pcall(entry and entry.f or special[op], a, b)
	if ok then
		if entry and entry.try then
			got = got[1] == 1 and reprs[entry.show_as].show(got[2]) or "fail"
		elseif entry then
			got = reprs[entry.show_as or t].show(got)
		end
	elseif type(got) == "table" and got.roc_crash then
		got = want:find("^crash:") and ("crash:" .. got.message) or "crash"
	else
		error(("%s(%s, %s): Lua error %s"):format(op, sa, sb, tostring(got)), 0)
	end
	total = total + 1
	per_op[op] = (per_op[op] or 0) + 1
	if got ~= want then
		failures = failures + 1
		if failures <= 20 then
			io.stderr:write(("FAIL %s(%s, %s): got %s, want %s\n"):format(op, sa, sb, got, want))
		end
	end
	::continue::
end
file:close()

local nops = 0
for _ in pairs(per_op) do nops = nops + 1 end
print(("numeric_vectors: %d vectors over %d ops, %d failed"):format(total, nops, failures))
if total == 0 then
	print("numeric_vectors: no vectors read")
	os.exit(1)
end
os.exit(failures == 0 and 0 or 1)
