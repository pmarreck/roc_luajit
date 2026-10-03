-- Str values built by concatenation: views into append-only buffers must
-- behave exactly like the plain Lua strings they stand for. Random concat
-- histories (seeded, reproducible) append to the newest value and to older
-- ones alike, and every value ever produced is compared with a reference
-- built by plain `..`. Run with: luajit luajit_backend/tests/runtime_strings.lua
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = here .. "/../../src/backend/lua/"
local W = dofile(src .. "wide.lua")
local rt = assert(loadfile(src .. "runtime.lua"))(W, dofile(src .. "int128.lua")(W), dofile(src .. "list.lua"), dofile(src .. "float.lua"), dofile(src .. "sort.lua"), dofile(src .. "numparse.lua"), dofile(src .. "fmath.lua"), dofile(src .. "simd.lua"), dofile(src .. "crypto.lua"))

local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		if failures <= 20 then
			io.stderr:write(("FAIL %s: got %s, want %s\n"):format(label, tostring(got), tostring(want)))
		end
	end
end

-- Park-Miller: reproducible without depending on math.random's generator.
local seed = 20261001
local function rand(n)
	seed = seed * 16807 % 2147483647
	return seed % n
end
local pieces = { "", "a", "bc", "héllo", "\0\1\2", ("x"):rep(40), ("long piece "):rep(9) }

for history = 1, 200 do
	local values, refs = { "" }, { "" }
	for step = 1, 120 do
		-- Mostly extend the newest value; sometimes an older one, or join two.
		local i = rand(4) == 0 and rand(#values) + 1 or #values
		local right, right_ref
		if rand(6) == 0 then
			local j = rand(#values) + 1
			right, right_ref = values[j], refs[j]
		else
			right = pieces[rand(#pieces) + 1]
			right_ref = right
		end
		values[#values + 1] = rt.str_concat(values[i], right)
		refs[#refs + 1] = refs[i] .. right_ref
		local label = ("history %d step %d"):format(history, step)
		check(label .. " length", rt.str_count_utf8_bytes(values[#values]), 0ULL + #refs[#refs])
	end
	for k = 1, #values do
		check(("history %d value %d"):format(history, k), rt.str(values[k]), refs[k])
		check(("history %d value %d is_eq"):format(history, k), rt.str_is_eq(values[k], refs[k]), true)
	end
end

-- Extending the newest value appends to its buffer in place; extending an
-- older one copies its prefix to a new buffer, leaving the newer value intact.
local base = rt.str_concat(("x"):rep(100), "y")
check("long concat is a view", type(base), "table")
local tip = rt.str_concat(base, "z")
check("tip append shares the buffer", tip.b, base.b)
local branch = rt.str_concat(base, "w")
check("non-tip append copies", branch.b ~= base.b, true)
check("tip value intact", rt.str(tip), ("x"):rep(100) .. "yz")
check("branch value", rt.str(branch), ("x"):rep(100) .. "yw")
check("short concat stays a string", type(rt.str_concat("ab", "cd")), "string")

-- Deep materialization (hosted arguments, entry results): views inside
-- records, tag payloads and list allocations become strings.
local list = rt.L.literal(8, { base, "plain" }, 2)
local value = { 1, { tip, list } }
rt.str_deep(value)
check("deep: record field", value[2][1], ("x"):rep(100) .. "yz")
check("deep: list element", list[1][1], ("x"):rep(100) .. "y")
check("deep: list element untouched", list[1][2], "plain")

if failures > 0 then
	io.stderr:write(("runtime_strings: %d failures\n"):format(failures))
	os.exit(1)
end
print("runtime_strings: all passed")
