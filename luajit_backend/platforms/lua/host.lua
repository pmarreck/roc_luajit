-- The Lua platform's host. Its core (codec, ops, real effects) is run by both
-- builds of a program: the native host embeds LuaJIT and this file, and
-- forwards each host call's bytes to `M.new(M.default_ports).dispatch`; for
-- `--target=luajit` this file is the host itself (`M.run`, at the end). Roc reaches every effect through one hosted function,
-- `host_call!(op, request) => response`, whose request and response are
-- LuaValue bytes (the codec below; the Roc side has the same codec), so the
-- two builds of a program share one implementation of every effect.
--
-- Codec (little-endian): 0x00 nil, 0x01 false, 0x02 true, 0x03 I64 (8 bytes),
-- 0x04 F64 (8 bytes, IEEE bits), 0x05 Str (U32 length + UTF-8 bytes), 0x06
-- table (U32 pair count + key, value pairs). Lua has one number type, so a
-- number that is integral and within +-2^53 encodes as I64 (an integral Num
-- sent from Roc comes back as Int), int64/uint64 cdata as I64 (uint64 past
-- I64's range is an error), every other number as F64 (NaN, infinities, -0).
-- Table keys encode sorted by type (boolean, number, string), then value,
-- since `next` order is not deterministic across LuaJIT states. Functions,
-- userdata, threads, other cdata, invalid UTF-8 strings and cycles are
-- errors: Roc has no value for them.
local ffi = require("ffi")
local bit = require("bit")

local M = {}

local int64_t, uint64_t = ffi.typeof("int64_t"), ffi.typeof("uint64_t")
local TWO53 = 2 ^ 53
local I64_MAX = 0x7fffffffffffffffULL

-- Encoding -------------------------------------------------------------------

local function u32(n)
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function int64_bytes(v)
	local u = ffi.cast(uint64_t, ffi.cast(int64_t, v))
	local out = {}
	for i = 1, 8 do
		out[i] = string.char(tonumber(bit.band(u, 0xff)))
		u = bit.rshift(u, 8)
	end
	return table.concat(out)
end
local dbl = ffi.new("double[1]")
local function f64_bytes(x)
	dbl[0] = x
	return ffi.string(dbl, 8)
end

-- Whether s is valid UTF-8 (no overlongs, surrogates or code points past
-- U+10FFFF), as Roc's Str requires.
local function valid_utf8(s)
	local i, n = 1, #s
	while i <= n do
		local c = s:byte(i)
		if c < 0x80 then
			i = i + 1
		else
			local len, min
			if c >= 0xC2 and c <= 0xDF then len, min = 2, 0x80
			elseif c >= 0xE0 and c <= 0xEF then len, min = 3, 0x800
			elseif c >= 0xF0 and c <= 0xF4 then len, min = 4, 0x10000
			else return false end
			if i + len - 1 > n then return false end
			local cp = bit.band(c, bit.rshift(0x7F, len))
			for j = 1, len - 1 do
				local b = s:byte(i + j)
				if bit.band(b, 0xC0) ~= 0x80 then return false end
				cp = cp * 64 + bit.band(b, 0x3F)
			end
			if cp < min or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return false end
			i = i + len
		end
	end
	return true
end

local key_rank = { boolean = 0, number = 1, string = 2 }
local function key_less(a, b)
	local ta, tb = type(a), type(b)
	if ta == "cdata" then a, ta = tonumber(a), "number" end
	if tb == "cdata" then b, tb = tonumber(b), "number" end
	if ta ~= tb then return key_rank[ta] < key_rank[tb] end
	if ta == "boolean" then return (not a) and b end
	return a < b
end

local function encode_into(out, v, visiting)
	local t = type(v)
	if v == nil then
		out[#out + 1] = "\0"
	elseif t == "boolean" then
		out[#out + 1] = v and "\2" or "\1"
	elseif t == "number" then
		if v == math.floor(v) and v > -TWO53 and v < TWO53 and not (v == 0 and 1 / v < 0) then
			out[#out + 1] = "\3" .. int64_bytes(v)
		else
			out[#out + 1] = "\4" .. f64_bytes(v)
		end
	elseif t == "cdata" and ffi.istype(int64_t, v) then
		out[#out + 1] = "\3" .. int64_bytes(v)
	elseif t == "cdata" and ffi.istype(uint64_t, v) then
		if v > I64_MAX then error("a uint64 past I64's range has no Roc value", 0) end
		out[#out + 1] = "\3" .. int64_bytes(v)
	elseif t == "string" then
		if not valid_utf8(v) then error("a string that is not valid UTF-8 has no Roc value", 0) end
		out[#out + 1] = "\5" .. u32(#v) .. v
	elseif t == "table" then
		if visiting[v] then error("a table that contains itself has no Roc value", 0) end
		visiting[v] = true
		local keys = {}
		for k in pairs(v) do
			local kt = type(k)
			if kt ~= "boolean" and kt ~= "number" and kt ~= "string" then
				error("a table key of type " .. kt .. " has no Roc value", 0)
			end
			keys[#keys + 1] = k
		end
		table.sort(keys, key_less)
		out[#out + 1] = "\6" .. u32(#keys)
		for _, k in ipairs(keys) do
			encode_into(out, k, visiting)
			encode_into(out, v[k], visiting)
		end
		visiting[v] = nil
	else
		error("a value of type " .. t .. " has no Roc value", 0)
	end
end

function M.encode(v)
	local out = {}
	encode_into(out, v, {})
	return (table.concat(out))
end

-- Decoding -------------------------------------------------------------------

local function read_u32(s, p)
	local a, b, c, d = s:byte(p, p + 3)
	if not d then error("truncated length", 0) end
	return a + b * 256 + c * 65536 + d * 16777216
end
local function read_int64(s, p)
	if p + 7 > #s then error("truncated I64", 0) end
	local u = 0ULL
	for i = 7, 0, -1 do u = bit.bor(bit.lshift(u, 8), s:byte(p + i)) end
	local v = ffi.cast(int64_t, u)
	if v > -TWO53 and v < TWO53 then return tonumber(v) end
	return v
end
local function read_f64(s, p)
	if p + 7 > #s then error("truncated F64", 0) end
	ffi.copy(dbl, s:sub(p, p + 7), 8)
	return dbl[0]
end

-- Returns the value at position p and the position after it.
local function decode_at(s, p)
	local tag = s:byte(p)
	if tag == nil then error("truncated value", 0) end
	if tag == 0 then return nil, p + 1 end
	if tag == 1 then return false, p + 1 end
	if tag == 2 then return true, p + 1 end
	if tag == 3 then return read_int64(s, p + 1), p + 9 end
	if tag == 4 then return read_f64(s, p + 1), p + 9 end
	if tag == 5 then
		local n = read_u32(s, p + 1)
		local first = p + 5
		if first + n - 1 > #s then error("truncated string", 0) end
		return s:sub(first, first + n - 1), first + n
	end
	if tag == 6 then
		local count = read_u32(s, p + 1)
		local t, q = {}, p + 5
		for _ = 1, count do
			local k, v
			k, q = decode_at(s, q)
			v, q = decode_at(s, q)
			if k == nil then error("nil table key", 0) end
			if type(k) == "cdata" then k = tonumber(k) end
			if k ~= k then error("NaN table key", 0) end
			t[k] = v
		end
		return t, q
	end
	error(("unknown tag %d"):format(tag), 0)
end

function M.decode(s)
	local v, p = decode_at(s, 1)
	if p ~= #s + 1 then error("bytes after the value", 0) end
	return v
end

-- Ops --------------------------------------------------------------------------

-- `ports` are the effects: write_stdout(s), write_stderr(s),
-- read_stdin_line() -> string or nil at end of input, getenv(name) ->
-- string or nil, read_file(path) -> data or nil, error kind, write_file(path,
-- data, append) -> true or nil, error kind, delete_file(path) -> true or nil,
-- error kind. Requests are arrays of arguments; responses are tables: { ok =
-- true, value = v } on success (no `value` field for nil), else fields
-- named by the op.
function M.new(ports)
	-- One environment for every eval in the run: globals a snippet defines
	-- persist for later evals, and the standard globals show through.
	local env = setmetatable({}, { __index = _G })
	local ops = {}

	function ops.eval(code, ...)
		if type(code) ~= "string" then error("eval needs code", 0) end
		local chunk, err = load(code, "=eval", "t", env)
		if not chunk then return { err = "syntax", msg = err } end
		local ok, result = pcall(chunk, ...)
		if not ok then return { err = "runtime", msg = tostring(result) } end
		-- Check the result is representable here, so the error is a Roc value.
		local encodable, why = pcall(M.encode, result)
		if not encodable then return { err = "runtime", msg = "result: " .. tostring(why) } end
		return { ok = true, value = result }
	end
	function ops.stdout_line(s) ports.write_stdout(s .. "\n") return { ok = true } end
	function ops.stdout_write(s) ports.write_stdout(s) return { ok = true } end
	function ops.stderr_line(s) ports.write_stderr(s .. "\n") return { ok = true } end
	function ops.stderr_write(s) ports.write_stderr(s) return { ok = true } end
	function ops.stdin_line()
		local line = ports.read_stdin_line()
		if line == nil then return { eof = true } end
		if not valid_utf8(line) then return { err = "BadUtf8" } end
		return { ok = true, value = line }
	end
	function ops.env_var(name)
		local v = ports.getenv(name)
		if v == nil then return { missing = true } end
		if not valid_utf8(v) then return { err = "BadUtf8" } end
		return { ok = true, value = v }
	end
	function ops.file_read(path)
		local data, kind = ports.read_file(path)
		if data == nil then return { err = kind } end
		if not valid_utf8(data) then return { err = "BadUtf8" } end
		return { ok = true, value = data }
	end
	function ops.file_write(path, data)
		local ok, kind = ports.write_file(path, data, false)
		if not ok then return { err = kind } end
		return { ok = true }
	end
	function ops.file_append(path, data)
		local ok, kind = ports.write_file(path, data, true)
		if not ok then return { err = kind } end
		return { ok = true }
	end
	function ops.file_delete(path)
		local ok, kind = ports.delete_file(path)
		if not ok then return { err = kind } end
		return { ok = true }
	end

	local core = {}
	-- One host call: decode the request, run the op, encode its response.
	-- An unknown op or a malformed request is a host error (a bug in the
	-- platform's Roc side), raised rather than returned.
	function core.dispatch(op, request)
		local f = ops[op]
		if not f then error("unknown platform op " .. tostring(op), 0) end
		local args = M.decode(request)
		return (M.encode(f(unpack(args, 1, table.maxn(args)))))
	end
	return core
end

-- Real effects through LuaJIT's io and os libraries, for both hosts.
local function io_kind(msg)
	msg = tostring(msg)
	if msg:find("No such file", 1, true) then return "NotFound" end
	if msg:find("Permission denied", 1, true) then return "PermissionDenied" end
	if msg:find("Is a directory", 1, true) then return "IsADirectory" end
	return "Other"
end
M.default_ports = {
	write_stdout = function(s) io.stdout:write(s) end,
	write_stderr = function(s) io.stderr:write(s) end,
	read_stdin_line = function() return io.stdin:read("*l") end,
	getenv = os.getenv,
	read_file = function(path)
		local f, err = io.open(path, "rb")
		if not f then return nil, io_kind(err) end
		local data, rerr = f:read("*a")
		f:close()
		if not data then return nil, io_kind(rerr) end
		return data
	end,
	write_file = function(path, data, append)
		local f, err = io.open(path, append and "ab" or "wb")
		if not f then return nil, io_kind(err) end
		local ok, werr = f:write(data)
		f:close()
		if not ok then return nil, io_kind(werr) end
		return true
	end,
	delete_file = function(path)
		local ok, err = os.remove(path)
		if not ok then return nil, io_kind(err) end
		return true
	end,
}

-- The LuaJIT host (`roc build --target=luajit`): bind the hosted call, pass
-- the arguments to roc_main, exit with its status.
function M.run(app, argv)
	local rt
	local core = M.new(M.default_ports)
	local program = app({
		lua_platform_host_call = function(op, request)
			return (rt.str_to_utf8(core.dispatch(rt.str(op), rt.list_bytes(request))))
		end,
	})
	rt = program.rt
	local args = {}
	for i = 1, #argv do args[i] = argv[i] end
	local ok, status, failure = rt.call_entry(program.entrypoints.roc_main, rt.host_str_list(args))
	io.stdout:flush()
	if ok then os.exit(tonumber(status)) end
	if failure == "stack_overflow" then
		io.stderr:write("\nThis Roc application overflowed its stack memory and crashed.\n\n")
		os.exit(134)
	end
	io.stderr:write("Roc crashed: ", tostring(status), "\n")
	os.exit(1)
end

return M
