-- The performance-profile adapter's core (luajit_backend/bench/profile/adapter.lua),
-- run against a fake Roc program and injected clocks and GC:
--   * the generated program's host trailer is swapped for `return APP`, and
--     anything else is refused;
--   * every configured size yields the protocol's rows, warmups excluded;
--   * wrong, missing or crashed work is an error, never a sample;
--   * the memory kind reports GC bytes allocated per run (collector stopped)
--     and residual bytes after a full collection, and leaves the GC running.
-- Run with: luajit luajit_backend/tests/profile_adapter.lua
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local A = dofile(here .. "/../bench/profile/adapter.lua")

local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		io.stderr:write(("FAIL %s: got %s, want %s\n"):format(label, tostring(got), tostring(want)))
	end
end
local function fails_with(label, fn, needle)
	local ok, err = pcall(fn)
	check(label .. " fails", ok, false)
	check(label .. " says why", type(err) == "string" and err:find(needle, 1, true) ~= nil, true)
end

-- Program factory.
local trailer = "local APP = function(...) return ... end\nlocal HOST = {}\nHOST.run(APP, arg)\n"
local factory = A.program_factory(trailer)
check("trailer swapped for the factory", type(factory), "function")
check("factory is APP", factory("x"), "x")
fails_with("other trailer", function() A.program_factory("print(1)\n") end, "HOST.run(APP, arg)")

-- A fake program: echoes twice its argument count; `behavior` injects faults.
local calls = 0
local function fake_app(behavior)
	return function(hosted)
		local rt = {
			host_str_list = function(strings) return strings end,
			call_entry = function(entry, list)
				return pcall(entry, list)
			end,
		}
		local entry = function(list)
			calls = calls + 1
			if behavior == "crash" then error("boom") end
			if behavior ~= "skip" then
				local n = #list * 2
				if behavior == "wrong" then n = n + 1 end
				hosted.roc_default_echo_line(tostring(n) .. "\n")
			end
			return 0
		end
		return { entrypoints = { roc_default_start_main = entry }, rt = rt }
	end
end
local function oracle(n) return tostring(n * 2) .. "\n" end

-- Injected clocks: each read advances by a fixed step (1 ms CPU, 2 ms wall).
local function stepping(step)
	local t = 0
	return function() t = t + step return t end
end
local function opts(behavior, kind, gc)
	return {
		app = fake_app(behavior), oracle = oracle, sizes = { 4, 8 }, kind = kind or "time",
		warmups = 3, samples = 5,
		clock = { cpu = stepping(1e6), wall = stepping(2e6) },
		gc = gc or { count_bytes = function() return 0 end, collect = function() end, stop = function() end, restart = function() end },
		jit = { set_sink = function() end },
	}
end

calls = 0
local m = A.measure(opts())
check("schema", m.schema, "performance-measurement/v1")
check("correct", m.correct, true)
check("one row per size", #m.rows, 2)
check("sizes in order", m.rows[1].size .. "," .. m.rows[2].size, "4,8")
check("five cpu samples", #m.rows[2].samples.cpu_ns, 5)
check("cpu sample is the clock delta", m.rows[1].samples.cpu_ns[1], 1e6)
check("wall sample is the clock delta", m.rows[1].samples.wall_ns[1], 2e6)
check("warmups run but are not samples", calls, 2 * (3 + 5))

fails_with("wrong output", function() A.measure(opts("wrong")) end, "output differs")
fails_with("skipped work", function() A.measure(opts("skip")) end, "output differs")
fails_with("crash", function() A.measure(opts("crash")) end, "crashed")

-- Memory kind: a fake GC whose heap grows by 100 bytes per argument while
-- stopped and keeps `leak` bytes after each collection.
local function fake_gc(leak)
	local g = { bytes = 1000, running = true, stops = 0, restarts = 0 }
	g.count_bytes = function() return g.bytes end
	g.collect = function() g.bytes = g.base_after_collect or g.bytes end
	g.stop = function() g.running = false g.stops = g.stops + 1 g.mark = g.bytes end
	g.restart = function() g.running = true g.restarts = g.restarts + 1 end
	g.on_run = function(n)
		g.bytes = g.bytes + 100 * n
		g.base_after_collect = (g.mark or g.bytes) + leak
	end
	return g
end
local function memory_opts(leak)
	local g = fake_gc(leak)
	local o = opts(nil, "memory", g)
	local app = o.app
	o.app = function(hosted)
		local p = app(hosted)
		local entry = p.entrypoints.roc_default_start_main
		p.entrypoints.roc_default_start_main = function(list) g.on_run(#list) return entry(list) end
		return p
	end
	return o, g
end
local mo, g = memory_opts(0)
m = A.measure(mo)
check("allocated bytes per run", m.rows[2].samples.total_bytes[1], 800)
check("no residual", m.rows[2].residual_bytes[1], 0)
check("three or more residuals", #m.rows[1].residual_bytes >= 3, true)
check("GC left running", g.running, true)
check("every stop restarted", g.stops, g.restarts)
check("coverage stated", type(m.allocator_coverage), "string")
mo = memory_opts(48)
m = A.measure(mo)
check("residual reported", m.rows[1].residual_bytes[1], 48)
-- Residuals are measured from one base before the sampled cycles, so a
-- per-run leak accumulates instead of hiding in per-cycle noise.
check("leak accumulates across cycles", m.rows[1].residual_bytes[3], 3 * 48)
check("raw heap delta kept", m.rows[1].heap_delta_bytes[3], 3 * 48)
-- A heap that ends below the base retained nothing from the cycles: the
-- residual is 0 and the raw (negative) delta is kept beside it.
mo = memory_opts(-64)
m = A.measure(mo)
check("shrunk heap retains nothing", m.rows[1].residual_bytes[2], 0)
check("shrunk heap delta kept", m.rows[1].heap_delta_bytes[2], -128)

-- LuaJIT's string table grows while the collector is stopped and each later
-- collection shrinks it only part of the way (measured: 4935, 1863, 1095,
-- 903, 871, 871 KB). The residual is read once collections stop shrinking
-- the heap, so that lag is not reported as retained memory.
do
	local g = { bytes = 1000, excess = 0 }
	g.count_bytes = function() return g.bytes + g.excess end
	g.collect = function() g.excess = math.floor(g.excess / 2) end
	g.stop = function() end
	g.restart = function() end
	local o = opts(nil, "memory", g)
	local app = o.app
	o.app = function(hosted)
		local p = app(hosted)
		local entry = p.entrypoints.roc_default_start_main
		p.entrypoints.roc_default_start_main = function(list) g.excess = g.excess + 4096 * #list return entry(list) end
		return p
	end
	m = A.measure(o)
	check("string-table lag is not residual", m.rows[2].heap_delta_bytes[5], 0)
end

-- Timed samples start from a settled heap (collections until the heap stops
-- shrinking), outside the timed region: a Roc program normally runs once in a
-- fresh process, and the harness's own earlier runs must not leave it a
-- bloated string table to sweep. The steady kind runs back to back without
-- settling, as a long-running program would. Both say which they did.
do
	local events = {}
	local g = { bytes = 1000 }
	g.count_bytes = function() return g.bytes end
	g.collect = function() events[#events + 1] = "collect" end
	g.stop = function() end
	g.restart = function() end
	local o = opts(nil, "time", g)
	local cpu = o.clock.cpu
	o.clock.cpu = function() events[#events + 1] = "clock" return cpu() end
	local mt = A.measure(o)
	check("time kind records settling", mt.heap_settled, true)
	-- Each sample: collections, then the clock reads.
	local settled_before_each, last = 0, nil
	for _, e in ipairs(events) do
		if e == "clock" and last == "collect" then settled_before_each = settled_before_each + 1 end
		last = e
	end
	check("a settle precedes every timed sample", settled_before_each, 2 * 5)
	events = {}
	local os_ = opts(nil, "steady", g)
	os_.clock.cpu = o.clock.cpu
	local ms = A.measure(os_)
	check("steady kind records no settling", ms.heap_settled, false)
	local collects = 0
	for _, e in ipairs(events) do if e == "collect" then collects = collects + 1 end end
	check("steady kind never collects", collects, 0)
	check("steady kind has timing rows", #ms.rows[1].samples.cpu_ns, 5)
end

-- Memory kind turns allocation sinking off before the first run (warmups
-- included) and records it: whether LuaJIT sinks a short-lived table varies
-- by process and can switch mid-sweep (str_build: 11.6 MB sunk, 22.9 MB not,
-- a switch read 3.04/2.31/2.14), so allocation counts are measured as the
-- program's own allocations. Timing kinds keep sinking on.
do
	local calls = {}
	local o = opts(nil, "memory", fake_gc(0))
	o.jit = { set_sink = function(on) calls[#calls + 1] = on end }
	local app = o.app
	local ran_before_set
	o.app = function(hosted)
		local p = app(hosted)
		local entry = p.entrypoints.roc_default_start_main
		p.entrypoints.roc_default_start_main = function(list)
			if #calls == 0 then ran_before_set = true end
			return entry(list)
		end
		return p
	end
	local mm = A.measure(o)
	check("memory kind turns sinking off once", #calls == 1 and calls[1], false)
	check("no run before sinking is off", ran_before_set, nil)
	check("memory kind records sinking off", mm.jit_sink, false)
	calls = {}
	local ot = opts(nil, "time")
	ot.jit = { set_sink = function(on) calls[#calls + 1] = on end }
	local mt = A.measure(ot)
	check("time kind leaves sinking alone", #calls, 0)
	check("time kind records sinking on", mt.jit_sink, true)
end

-- Memory kind warms every size before the first sampled cycle of any size:
-- with sinking off, dict_ops' traces kept appearing during the first size's
-- cycles (residual 31.9, 67.4, 74.5, 74.6 KB, then flat; later sizes 1-4 KB),
-- which reads as a leak. A real leak still accumulates per cycle.
do
	local events = {}
	local g = fake_gc(0)
	local stop = g.stop
	g.stop = function() events[#events + 1] = "sample" stop() end
	local o = opts(nil, "memory", g)
	local app = o.app
	o.app = function(hosted)
		local p = app(hosted)
		local entry = p.entrypoints.roc_default_start_main
		p.entrypoints.roc_default_start_main = function(list) events[#events + 1] = #list return entry(list) end
		return p
	end
	A.measure(o)
	local first_sample
	for i, e in ipairs(events) do if e == "sample" then first_sample = i break end end
	local warmed = {}
	for i = 1, first_sample - 1 do warmed[events[i]] = (warmed[events[i]] or 0) + 1 end
	check("size 4 warmed before any sample", warmed[4], 3)
	check("size 8 warmed before any sample", warmed[8], 3)
	local runs = 0
	for _, e in ipairs(events) do if e ~= "sample" then runs = runs + 1 end end
	check("each size warmed once, not twice", runs, 2 * (3 + 5))
end

if failures == 0 then
	print("profile_adapter: all passed")
	os.exit(0)
end
print(("profile_adapter: %d failed"):format(failures))
os.exit(1)
