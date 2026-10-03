-- performance-profile driver: luajit driver.lua APP_LUA NATIVE KIND SIZES SEED
-- Measures one generated program in-process with the adapter core and prints
-- the readiness marker, then one performance-measurement/v1 JSON object.
-- NATIVE is the same program built natively; its stdout at each size is the
-- oracle, computed before any timing. KIND is time (heap settled before each
-- sample), steady (back to back, no settling) or memory.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local A = dofile(here .. "/adapter.lua")
local uv = require("luv")
local json = require("cjson")

local app_lua, native, kind, sizes_text, seed = arg[1], arg[2], arg[3], arg[4], arg[5]
if not (app_lua and native and (kind == "time" or kind == "steady" or kind == "memory") and sizes_text and seed) then
	io.stderr:write("usage: luajit driver.lua APP_LUA NATIVE time|steady|memory SIZES SEED\n")
	os.exit(2)
end
if not jit.status() then
	io.stderr:write("driver: the JIT is off; refusing to measure the interpreter\n")
	os.exit(1)
end

local sizes = {}
for text in sizes_text:gmatch("[^,]+") do sizes[#sizes + 1] = assert(tonumber(text), "sizes must be integers") end

-- Native stdout with `n` arguments; a failing native run is an error.
local function oracle(n)
	local parts = { ("%q"):format(native) }
	for i = 1, n do parts[#parts + 1] = "a" end
	local p = assert(io.popen(table.concat(parts, " ") .. " </dev/null", "r"))
	local out = p:read("*a")
	local ok, how, code = p:close()
	if not ok then error(("native build failed at %d arguments (%s %s)"):format(n, tostring(how), tostring(code)), 0) end
	return out
end
-- Computed on first use, which is after the readiness marker: startup is the
-- program's load, not the native oracle's runs. Still before any timing.
local expected = setmetatable({}, { __index = function(t, n) local v = oracle(n) rawset(t, n, v) return v end })

local f = assert(io.open(app_lua, "rb"))
local source = f:read("*a")
f:close()

local NS = 1e9
-- Memory runs warm longer so the JIT's traces (GC objects the trace table
-- keeps) mostly exist before the residual base is taken.
local WARMUPS = kind == "memory" and 10 or 3
-- Four samples per size: within-process spread is mostly under 5%, so four
-- keep the noise statistics meaningful at 80% of the cost of five.
local SAMPLES = 4
local ok, result = pcall(A.measure, {
	app = A.program_factory(source),
	oracle = function(n) return expected[n] end,
	sizes = sizes,
	kind = kind,
	warmups = WARMUPS,
	samples = SAMPLES,
	clock = {
		cpu = function() return math.floor(os.clock() * NS + 0.5) end,
		wall = function() return tonumber(uv.hrtime()) end,
	},
	gc = {
		count_bytes = function() return collectgarbage("count") * 1024 end,
		collect = function() collectgarbage("collect") end,
		stop = function() collectgarbage("stop") end,
		restart = function() collectgarbage("restart") end,
	},
	ready = function()
		io.stdout:write("performance-ready/v1\n")
		io.stdout:flush()
	end,
})
if not ok then
	io.stderr:write("driver: ", tostring(result), "\n")
	os.exit(1)
end
result.build_mode = "luajit-jit"
result.runtime = jit.version
result.seed = seed
result.clocks = {
	cpu_ns = "os.clock() (process CPU time), one program run per sample",
	wall_ns = "luv hrtime (monotonic), one program run per sample",
}
result.warmups_per_size = WARMUPS
result.samples_per_size = SAMPLES
io.stdout:write(json.encode(result), "\n")
