-- Disposable M0 probe: how the answer to Roc's runtime uniqueness checks
-- changes the growth of `List.append` loops on LuaJIT.
--
-- Roc's `List.append` is `list_append_unsafe(List.reserve(list, 1), item)`
-- (src/build/roc/Builtin.roc:4113-4116). `list_reserve` reads the refcount:
-- unique => grow in place, shared => copy (src/builtins/list.zig:643-688).
-- This models the two sound GC-backend policies:
--   counted: follow LIR incref/decref, keep a real count, answer checks from it
--   never:   treat incref/decref as no-ops, answer every check "not unique"
-- It measures growth ratios per doubling of N, not absolute speed.

local function new_list() return { rc = 1, n = 0 } end

local function copy(list)
	local out = { rc = 1, n = list.n }
	for i = 1, list.n do out[i] = list[i] end
	return out
end

-- list_reserve consumes its argument (owned), like the native builtin.
local reserve = {
	counted = function(list)
		if list.rc == 1 then return list end
		list.rc = list.rc - 1
		return copy(list)
	end,
	never = function(list) return copy(list) end,
}

local function append_loop(policy, n)
	local res = reserve[policy]
	local acc = new_list()
	for i = 1, n do
		acc = res(acc)
		local len = acc.n + 1
		acc[len] = i
		acc.n = len
	end
	return acc
end

local function cpu_time(policy, n, reps)
	local best = math.huge
	for _ = 1, reps do
		collectgarbage("collect")
		local t0 = os.clock()
		local out = append_loop(policy, n)
		local dt = os.clock() - t0
		assert(out.n == n and out[n] == n)
		if dt < best then best = dt end
	end
	return best
end

local sizes_for = { counted = { 250000, 500000, 1000000, 2000000 }, never = { 4000, 8000, 16000, 32000 } }
for _, policy in ipairs({ "counted", "never" }) do
	local prev
	for _, n in ipairs(sizes_for[policy]) do
		local t = cpu_time(policy, n, 5)
		local ratio = prev and string.format("%.2f", t / prev) or "-"
		print(string.format("%-8s n=%6d cpu=%.6fs ratio=%s", policy, n, t, ratio))
		prev = t
	end
end
