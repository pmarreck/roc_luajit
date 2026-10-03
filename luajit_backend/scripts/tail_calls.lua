-- Tail calls in the LuaJIT runtime, found from its bytecode.
--
-- LuaJIT counts every tail call against the loop-unroll limit of the trace
-- being recorded (lj_record_tailcall), and a function whose last act is a
-- tail call to a builtin (`return bit.bxor(a, b)`, `return ffi.cast(t, v)`)
-- returns from a non-Lua frame, which a root trace cannot record ("leaving
-- loop in root trace"). Such helpers get blacklisted, and every loop trace
-- that calls a blacklisted function then aborts too. A tail call whose callee
-- returns exactly one value is therefore written `return (f(...))`.
--
-- This script loads the runtime modules the way the emitted prelude does,
-- walks every reachable closure (module tables, then upvalues), and for each
-- CALLT/CALLMT resolves the callee through the instruction that loaded it
-- (UGET, GGET, TGETS over a resolved table) and classifies it:
--   single   a Lua function whose every return yields one value (RET0/RET1,
--            or a tail call to a single callee), or a builtin listed below;
--   multi    anything that can return several values;
--   unknown  a callee the bytecode does not determine.
-- Prototypes no reachable closure instantiates (closures made per call)
-- resolve their upvalues by name in the closure that defines them.
--
-- Usage: luajit tail_calls.lua SRC_DIR [--check]
-- Prints `file:line class callee` per tail call; with --check exits 1 when
-- any tail call has a single-valued callee (the suite's lint).
local jutil = require("jit.util")
local vmdef = require("jit.vmdef")
local funcinfo, funcbc, funck, funcuvname = jutil.funcinfo, jutil.funcbc, jutil.funck, jutil.funcuvname
local bcnames, ffnames = vmdef.bcnames, vmdef.ffnames

local src, check = arg[1], arg[2] == "--check"
assert(src, "usage: tail_calls.lua SRC_DIR [--check]")
src = src:gsub("/?$", "/")

-- Load the runtime as the emitter's prelude composes it.
local W = dofile(src .. "wide.lua")
local I = dofile(src .. "int128.lua")(W)
local L, F, S, NP = dofile(src .. "list.lua"), dofile(src .. "float.lua"), dofile(src .. "sort.lua"), dofile(src .. "numparse.lua")
local FM, SI, CR = dofile(src .. "fmath.lua"), dofile(src .. "simd.lua"), dofile(src .. "crypto.lua")
local rt = assert(loadfile(src .. "runtime.lua"))(W, I, L, F, S, NP, FM, SI, CR)

-- Builtins (fast functions) that return exactly one value.
local single_builtin = {}
for name in ([[bit.tobit bit.tohex bit.bnot bit.band bit.bor bit.bxor bit.lshift bit.rshift bit.arshift
	bit.rol bit.ror bit.bswap math.abs math.floor math.ceil math.sqrt math.log math.log10 math.exp
	math.sin math.cos math.tan math.asin math.acos math.atan math.atan2 math.sinh math.cosh math.tanh
	math.pow math.fmod math.ldexp math.min math.max math.random math.deg math.rad tonumber tostring
	type rawget rawequal rawlen setmetatable getmetatable string.len string.sub string.rep
	string.reverse string.lower string.upper string.char string.format table.concat table.insert
	ffi.cast ffi.new ffi.typeof ffi.string ffi.sizeof ffi.alignof ffi.offsetof ffi.istype ffi.abi
	ffi.copy ffi.fill ffi.gc ffi.metatype]]):gmatch("%S+") do
	single_builtin[name] = true
end

local function op_of(ins) return bcnames:sub(6 * (ins % 256) + 1, 6 * (ins % 256) + 6):gsub(" +$", "") end
local function a_of(ins) return bit.band(bit.rshift(ins, 8), 0xff) end
local function b_of(ins) return bit.rshift(ins, 24) end
local function c_of(ins) return bit.band(bit.rshift(ins, 16), 0xff) end
local function d_of(ins) return bit.rshift(ins, 16) end

-- An upvalue's name and value: from a closure itself, or, for a prototype no
-- reachable closure instantiates, by name from the closure that defines it.
local function upvalue(fn, idx, parent)
	if type(fn) == "function" then return debug.getupvalue(fn, idx + 1) end
	local name = funcuvname(fn, idx)
	for i = 1, math.huge do
		local pname, value = debug.getupvalue(parent, i)
		if not pname then return name, nil end
		if pname == name then return name, value end
	end
end

-- The value held in `slot` just before `pc`: the last instruction before it
-- that writes the slot, if that is a load this script can follow.
local function slot_value(fn, pc, slot, parent)
	for p = pc - 1, 1, -1 do
		local ins = funcbc(fn, p)
		local op = op_of(ins)
		if a_of(ins) == slot and not op:match("^IS") and not op:match("^RET") and op ~= "JMP" and not op:match("^T?SET") then
			if op == "UGET" then
				local name, value = upvalue(fn, d_of(ins), parent)
				return value ~= nil, value, name
			elseif op == "GGET" then
				local key = funck(fn, -d_of(ins) - 1)
				return true, getfenv(parent or fn)[key], key
			elseif op == "TGETS" then
				local ok, base, base_name = slot_value(fn, p, b_of(ins), parent)
				local key = funck(fn, -c_of(ins) - 1)
				if ok and type(base) == "table" then return true, base[key], (base_name or "?") .. "." .. key end
				return false, nil, (base_name or "?") .. "." .. key
			elseif op == "MOV" then
				return slot_value(fn, p, d_of(ins), parent)
			end
			return false, nil, op
		end
	end
	return false, nil, "entry"
end

local classify -- forward

-- Whether a Lua function returns exactly one value on every path, as a
-- greatest fixpoint over the functions it tail-calls: every function reached
-- starts out single, and passes over all of them demote one with a
-- multi-value return or a tail call to a demoted one, until a pass changes
-- nothing. Mutually tail-calling functions are thus decided together (a
-- first guess kept for one member of a cycle could outlive the other's
-- demotion). Demotion is one-way, so the passes terminate.
local guess, known = {}, {}
local function single_guess(fn)
	if guess[fn] == nil then
		guess[fn] = true
		known[#known + 1] = fn
	end
	return guess[fn]
end
-- One scan of fn under the current guesses (registering its callees).
local function scan(fn)
	for pc = 1, math.huge do
		local ins = funcbc(fn, pc)
		if not ins then return true end
		local op = op_of(ins)
		if op == "RETM" or (op == "RET" and d_of(ins) ~= 2) then return false end
		if (op == "CALLT" or op == "CALLMT") and classify(fn, pc, nil, single_guess) ~= "single" then return false end
	end
end
local function returns_single(fn)
	single_guess(fn)
	repeat
		local changed = false
		local i = 1
		while i <= #known do
			local g = known[i]
			if guess[g] and not scan(g) then
				guess[g] = false
				changed = true
			end
			i = i + 1
		end
	until not changed
	return guess[fn]
end

local names = setmetatable({}, { __mode = "k" })
-- `single` decides a Lua callee: returns_single, or the current guess while
-- the fixpoint above is being computed.
function classify(fn, pc, parent, single)
	local ok, callee, name = slot_value(fn, pc, a_of(funcbc(fn, pc)), parent)
	names[pc] = name
	if not ok or type(callee) ~= "function" then return "unknown", name end
	local info = funcinfo(callee)
	if info.ffid then
		local ffname = ffnames[info.ffid]
		return single_builtin[ffname] and "single" or "multi", name
	end
	if info.addr then return "unknown", name end -- a C function
	return (single or returns_single)(callee) and "single" or "multi", name
end

-- Every reachable Lua closure.
local closures, seen = {}, {}
local function walk(v)
	if seen[v] then return end
	local t = type(v)
	if t ~= "function" and t ~= "table" then return end
	seen[v] = true
	if t == "table" then
		for k, x in pairs(v) do
			walk(k)
			walk(x)
		end
		local mt = getmetatable(v)
		if mt then walk(mt) end
		return
	end
	if funcinfo(v).ffid or funcinfo(v).addr then return end
	closures[#closures + 1] = v
	for i = 1, math.huge do
		local name, value = debug.getupvalue(v, i)
		if not name then break end
		walk(value)
	end
end
walk(rt)

-- Prototypes, keyed by definition site, so uninstantiated ones are found.
local function proto_key(p)
	local info = funcinfo(p)
	return info.source .. ":" .. info.linedefined .. ":" .. info.lastlinedefined
end
local covered = {}
for _, fn in ipairs(closures) do covered[proto_key(fn)] = true end

local sites, singles = {}, 0
local function report(fn, pc, class, callee)
	local info = funcinfo(fn, pc)
	local file = info.source:gsub("^@", ""):gsub("^.*/", "")
	local key = file .. ":" .. info.currentline .. " " .. class .. " " .. tostring(callee)
	if not sites[key] then
		sites[key] = true
		sites[#sites + 1] = key
		if class == "single" then singles = singles + 1 end
	end
end
for _, fn in ipairs(closures) do
	for pc = 1, math.huge do
		local ins = funcbc(fn, pc)
		if not ins then break end
		local op = op_of(ins)
		if op == "CALLT" or op == "CALLMT" then
			local class, callee = classify(fn, pc)
			report(fn, pc, class, callee)
		end
	end
end
local function protos(p, out)
	for i = -1, -math.huge, -1 do
		local k = funck(p, i)
		if k == nil then break end
		if type(k) == "proto" then
			out[#out + 1] = k
			protos(k, out)
		end
	end
	return out
end
for _, fn in ipairs(closures) do
	for _, p in ipairs(protos(fn, {})) do
		if not covered[proto_key(p)] then
			for pc = 1, math.huge do
				local ins = funcbc(p, pc)
				if not ins then break end
				local op = op_of(ins)
				if op == "CALLT" or op == "CALLMT" then
					local class, callee = classify(p, pc, fn)
					report(p, pc, class, callee)
				end
			end
		end
	end
end

table.sort(sites)
for _, line in ipairs(sites) do print(line) end
if check and singles > 0 then
	io.stderr:write(("tail_calls: %d tail calls to single-valued functions; write them `return (f(...))`\n"):format(singles))
	os.exit(1)
end
