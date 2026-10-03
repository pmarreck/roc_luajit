-- Core of the performance-profile adapter for programs built with
-- `roc build --target=luajit`: loads a generated program as a factory instead
-- of running it, instantiates it once, warms the JIT on the real entrypoint and
-- then times (or measures the GC allocations of) repeated verified runs inside
-- one process, emitting performance-measurement/v1 (see
-- $HOME/Code/performance_profiling/docs/PROTOCOL.md). Clocks and the GC are
-- injected so the protocol, verification and memory accounting are testable.
local M = {}

local TRAILER = "HOST.run(APP, arg)"

-- Turn a generated program's source into a function returning its APP
-- factory: the host trailer that would run it is replaced by `return APP`.
-- A program without exactly that trailer is refused rather than guessed at.
function M.program_factory(source)
	local body, last = source:gsub("\n+$", ""):match("^(.*\n)([^\n]*)$")
	if last ~= TRAILER then
		error("generated program does not end with " .. TRAILER .. "; the emitter's host trailer changed", 0)
	end
	local chunk = assert(loadstring(body .. "return APP\n", "=app.lua"))
	return chunk()
end

local function args_of(n)
	local list = {}
	for i = 1, n do list[i] = "a" end
	return list
end

-- One run of the entrypoint with `n` arguments; returns the echoed output.
-- A crash or a nonzero status is an error: it is never a measurement.
local function run_once(program, out, n)
	for i = #out, 1, -1 do out[i] = nil end
	local rt = program.rt
	local ok, status, failure = rt.call_entry(program.entrypoints.roc_default_start_main, rt.host_str_list(args_of(n)))
	if not ok then error(("program crashed at %d arguments: %s"):format(n, tostring(failure or status)), 0) end
	if status ~= 0 then error(("program exited %s at %d arguments"):format(tostring(status), n), 0) end
end

-- Collect until a collection stops shrinking the heap and return its size.
-- LuaJIT shrinks its string table only part of the way per collection, so
-- one or two collections after a run with the collector stopped still count
-- a lagging, oversized table.
-- complexity: at most SETTLE_LIMIT collections.
local SETTLE_LIMIT = 32
local function settled_bytes(gc)
	gc.collect()
	local prev = gc.count_bytes()
	for _ = 1, SETTLE_LIMIT do
		gc.collect()
		local now = gc.count_bytes()
		if now >= prev then return now end
		prev = now
	end
	error("the heap kept shrinking after " .. SETTLE_LIMIT .. " collections", 0)
end

local function verify(out, expected, n)
	local got = table.concat(out)
	if got ~= expected then
		error(("output differs from the native build at %d arguments: got %q, want %q"):format(n, got, expected), 0)
	end
end

-- Measure `opts.app` (an APP factory) at each of `opts.sizes` argument counts.
-- opts: oracle(n) -> expected stdout, kind "time" | "steady" | "memory", warmups,
-- samples, clock = { cpu, wall } (nanoseconds), gc = { count_bytes, collect,
-- stop, restart }, ready() called once the program is instantiated.
-- complexity: O(sum(sizes) * (warmups + samples)) runs of the program.
function M.measure(opts)
	local out = {}
	local hosted = {
		roc_default_echo_line = function(s)
			out[#out + 1] = s
		end,
	}
	local program = opts.app(hosted)
	hosted.roc_default_echo_line = (function(echo)
		return function(s)
			echo(s)
			return program.rt.ZST
		end
	end)(hosted.roc_default_echo_line)
	if opts.ready then opts.ready() end
	local rows = {}
	for _, n in ipairs(opts.sizes) do
		local expected = opts.oracle(n)
		for _ = 1, opts.warmups do
			run_once(program, out, n)
			verify(out, expected, n)
		end
		local row = { size = n, samples = {} }
		if opts.kind == "memory" then
			local gc = opts.gc
			local allocated, residual, delta = {}, {}, {}
			-- Residuals are measured from one base taken before the sampled
			-- cycles, so a per-run leak accumulates across cycles rather than
			-- hiding in the collector's per-cycle fluctuation.
			local cycles_base = settled_bytes(gc)
			for s = 1, opts.samples do
				local base = settled_bytes(gc)
				gc.stop()
				local ok, err = pcall(run_once, program, out, n)
				allocated[s] = gc.count_bytes() - base
				gc.restart()
				if not ok then error(err, 0) end
				verify(out, expected, n)
				for i = #out, 1, -1 do out[i] = nil end
				delta[s] = settled_bytes(gc) - cycles_base
				-- Below the base, nothing from the cycles was retained; the raw
				-- delta stays in heap_delta_bytes.
				residual[s] = math.max(0, delta[s])
			end
			row.samples.total_bytes = allocated
			row.residual_bytes = residual
			row.heap_delta_bytes = delta
		else
			-- time: every sample starts from a settled heap, as a fresh process
			-- would; steady: back to back, as a long-running program would.
			local cpu, wall = {}, {}
			for s = 1, opts.samples do
				if opts.kind == "time" then settled_bytes(opts.gc) end
				local c0, w0 = opts.clock.cpu(), opts.clock.wall()
				run_once(program, out, n)
				local w1, c1 = opts.clock.wall(), opts.clock.cpu()
				verify(out, expected, n)
				cpu[s], wall[s] = c1 - c0, w1 - w0
			end
			row.samples.cpu_ns, row.samples.wall_ns = cpu, wall
		end
		rows[#rows + 1] = row
	end
	local result = { schema = "performance-measurement/v1", correct = true, rows = rows, heap_settled = opts.kind ~= "steady" }
	if opts.kind == "memory" then
		result.allocator_coverage = "LuaJIT GC heap via collectgarbage('count'), collector stopped during each run; "
			.. "excludes JIT machine code and memory outside the GC (none is allocated by the runtime)"
	end
	return result
end

return M
