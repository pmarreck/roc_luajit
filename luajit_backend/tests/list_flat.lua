-- Flat element storage in list.lua: a list whose elements have k >= 2 leaves
-- stores leaf j of element i in allocation slot (offset + i) * k + j instead
-- of one table per element. Checked two ways:
--   * the template expander's output for k = 1 and k = 3;
--   * a differential: seeded random sequences of every list operation run on
--     a flat k-stride list and on the one-slot list holding each element as a
--     table, with shared and unique states and refcounted leaves, compared
--     after every step (elements, length, capacity, offset, slice flag,
--     uniqueness, returned elements, every leaf's reference count).
-- Run with: luajit luajit_backend/tests/list_flat.lua
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local src = here .. "/../../src/backend/lua/"
local ZST = setmetatable({}, { __name = "ZST" })
local function crash(msg) error({ message = msg }) end
local LIST = dofile(src .. "list.lua")
local SORT = dofile(src .. "sort.lua")
local L = LIST(crash, ZST, SORT)

local failures = 0
local function check(label, got, want)
	if got ~= want then
		failures = failures + 1
		if failures <= 25 then
			io.stderr:write(("FAIL %s: got %s, want %s\n"):format(label, tostring(got), tostring(want)))
		end
	end
end

-- Expander -----------------------------------------------------------------------
local expand = L.expand_template
check("expander exported", type(expand), "function")
if type(expand) == "function" then
	local cases = {
		{ "$E(elem)", 1, "elem" },
		{ "$E(elem)", 3, "elem_1, elem_2, elem_3" },
		{ "$S(a, o + i)", 1, "a[o + i]" },
		{ "$S(a, o + i)", 3, "a[(o + i) * 3 - 2], a[(o + i) * 3 - 1], a[(o + i) * 3]" },
		{ "$GET(l, i)", 1, "l[1][l[2] + (i) + 1]" },
		{ "$GET(l, i)", 2, "l[1][(l[2] + (i) + 1) * 2 - 1], l[1][(l[2] + (i) + 1) * 2]" },
		{ "$MAT($E(x))", 1, "x" },
		{ "$MAT($E(x))", 2, "mat(x_1, x_2)" },
		{ "$UNP(m[i])", 1, "m[i]" },
		{ "$UNP(m[i])", 2, "unp(m[i])" },
		{ "return $R(get(l, n))", 1, "return (get(l, n))" },
		{ "return $R(get(l, n))", 2, "return get(l, n)" },
		{ "x = $K", 4, "x = 4" },
		{ "inc($S(a, f(i, j)), 1)", 2, "inc(a[(f(i, j)) * 2 - 1], a[(f(i, j)) * 2], 1)" },
		{ "no macros (here)", 2, "no macros (here)" },
	}
	for _, c in ipairs(cases) do check(("expand %q k=%d"):format(c[1], c[2]), expand(c[1], c[2]), c[3]) end
end

-- Differential -------------------------------------------------------------------
local K = 3
local F = L.flat and L.flat(K)
check("flat(3) exists", type(F), "table")
if type(F) ~= "table" then
	print(("list_flat: %d failed"):format(failures))
	os.exit(1)
end
check("flat(3) is memoized", L.flat(K), F)
check("flat(1) is the one-slot module", L.flat(1), L)

-- A refcounted leaf: a box whose rc both runs track separately (same ids).
local rc_table, rc_flat = {}, {}
local function new_box(id) return { id = id } end
local function leaf_inc(counts, v, amount) if type(v) == "table" and v.id then counts[v.id] = (counts[v.id] or 0) + amount end end
local function leaf_dec(counts, v) if type(v) == "table" and v.id then counts[v.id] = (counts[v.id] or 0) - 1 end end
-- Table-list RC helpers take one element table; flat helpers take K leaves.
local function inc_t(t, amount) for j = 1, K do leaf_inc(rc_table, t[j], amount) end end
local function dec_t(t) for j = 1, K do leaf_dec(rc_table, t[j]) end end
local function inc_f(a, b, c, amount) leaf_inc(rc_flat, a, amount); leaf_inc(rc_flat, b, amount); leaf_inc(rc_flat, c, amount) end
local function dec_f(a, b, c) leaf_dec(rc_flat, a); leaf_dec(rc_flat, b); leaf_dec(rc_flat, c) end
local function mat(a, b, c) return { a, b, c } end
local function unp(t) return t[1], t[2], t[3] end

local W = 24 -- native byte width of a 3-field record (drives capacity growth)
local next_id = 0
-- Element leaves: a number, a refcounted box, and sometimes nil (a tag
-- variant's unused leaf) to check holes do not disturb the stride.
local function random_elem()
	next_id = next_id + 1
	local third = (math.random(4) == 1) and nil or next_id * 10
	return math.random(1000), new_box(next_id), third
end

local function leaf_str(v)
	if type(v) == "table" then return "box" .. v.id end
	return tostring(v)
end
local function elem_str(a, b, c) return leaf_str(a) .. "," .. leaf_str(b) .. "," .. leaf_str(c) end

local function same_list(label, lt, lf)
	check(label .. " length", lf[3], lt[3])
	check(label .. " capacity", L.capacity(lf), L.capacity(lt))
	check(label .. " offset", lf[2], lt[2])
	check(label .. " slice", lf[5], lt[5])
	check(label .. " has allocation", lf[1] ~= nil, lt[1] ~= nil)
	if lt[1] and lf[1] then
		check(label .. " unique", L.is_unique(lf), L.is_unique(lt))
		for i = 0, lt[3] - 1 do
			local t = L.get_unsafe(lt, i)
			check(("%s elem %d"):format(label, i), elem_str(F.get_unsafe(lf, i)), elem_str(unp(t)))
		end
	end
end

local function same_rc(label)
	for id = 1, next_id do check(("%s rc box%d"):format(label, id), rc_flat[id] or 0, rc_table[id] or 0) end
end

-- Build both lists from the same elements by appending.
local function build(n)
	local lt, lf = L.ll_with_capacity(0, W), F.ll_with_capacity(0, W)
	for _ = 1, n do
		local a, b, c = random_elem()
		lt = L.ll_append_unsafe(L.ll_reserve(lt, 1, W, inc_t, dec_t, false), { a, b, c }, W)
		lf = F.ll_append_unsafe(F.ll_reserve(lf, 1, W, inc_f, dec_f, false), a, b, c, W)
	end
	return lt, lf
end

local comparator_t = { proc = function(x, y) dec_t(x); dec_t(y); return { x[1] < y[1] and 1 or (x[1] > y[1] and 0 or 2) } end }
local comparator_f = { proc = function(x, y) dec_f(unp(x)); dec_f(unp(y)); return { x[1] < y[1] and 1 or (x[1] > y[1] and 0 or 2) } end }

local ops = {
	function(lt, lf) -- append
		local a, b, c = random_elem()
		return L.ll_append_unsafe(L.ll_reserve(lt, 1, W, inc_t, dec_t, false), { a, b, c }, W),
			F.ll_append_unsafe(F.ll_reserve(lf, 1, W, inc_f, dec_f, false), a, b, c, W)
	end,
	function(lt, lf) -- prepend
		local a, b, c = random_elem()
		return L.ll_prepend(lt, { a, b, c }, W, inc_t, dec_t, false), F.ll_prepend(lf, a, b, c, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- concat with a fresh list on either side
		local ot, of = build(math.random(0, 4))
		if math.random(2) == 1 then
			return L.ll_concat(lt, ot, W, inc_t, dec_t, false, false), F.ll_concat(lf, of, W, inc_f, dec_f, false, false)
		end
		return L.ll_concat(ot, lt, W, inc_t, dec_t, false, false), F.ll_concat(of, lf, W, inc_f, dec_f, false, false)
	end,
	function(lt, lf) -- sublist
		local n = lt[3]
		local rec = { math.random(0, n + 1), math.random(0, n + 1) } -- { len, start }
		return L.ll_sublist(lt, rec, W, dec_t, false), F.ll_sublist(lf, rec, W, dec_f, false)
	end,
	function(lt, lf) -- drop_at
		local i = math.random(0, lt[3] + 1)
		return L.ll_drop_at(lt, i, W, inc_t, dec_t, false), F.ll_drop_at(lf, i, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- swap
		local i, j = math.random(0, lt[3]), math.random(0, lt[3])
		return L.ll_swap(lt, i, j, W, inc_t, dec_t, false), F.ll_swap(lf, i, j, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- reverse
		return L.ll_reverse(lt, W, inc_t, dec_t, false), F.ll_reverse(lf, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- replace: the old element comes back
		if lt[3] == 0 then return lt, lf end
		local i = math.random(0, lt[3] - 1)
		local a, b, c = random_elem()
		local ot, old_t = L.ll_replace(lt, i, { a, b, c }, W, inc_t, dec_t, false)
		local of, o1, o2, o3 = F.ll_replace(lf, i, a, b, c, W, inc_f, dec_f, false)
		check("replace old element", elem_str(o1, o2, o3), elem_str(unp(old_t)))
		dec_t(old_t)
		dec_f(o1, o2, o3)
		return ot, of
	end,
	function(lt, lf) -- set
		if lt[3] == 0 then return lt, lf end
		local i = math.random(0, lt[3] - 1)
		local a, b, c = random_elem()
		return L.ll_set(lt, i, { a, b, c }, W, inc_t, dec_t, false), F.ll_set(lf, i, a, b, c, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- release_excess_capacity
		return L.ll_release_excess_capacity(lt, W, inc_t, dec_t, false), F.ll_release_excess_capacity(lf, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- append_range_within
		if lt[3] == 0 then return lt, lf end
		local start = math.random(0, lt[3] - 1)
		local count = math.random(0, lt[3] - start)
		return L.ll_append_range_within(lt, start, count, W, inc_t, dec_t, false), F.ll_append_range_within(lf, start, count, W, inc_f, dec_f, false)
	end,
	function(lt, lf) -- copy_range_within
		if lt[3] == 0 then return lt, lf end
		local count = math.random(0, lt[3])
		local dest, srcp = math.random(0, lt[3] - count), math.random(0, lt[3] - count)
		return L.ll_copy_range_within(lt, dest, srcp, count, W, inc_t, dec_t), F.ll_copy_range_within(lf, dest, srcp, count, W, inc_f, dec_f)
	end,
	function(lt, lf) -- append_sublist of a borrowed fresh list
		local ot, of = build(math.random(0, 5))
		local start = math.random(0, ot[3])
		local count = ot[3] - start
		local rt_, rf = L.ll_append_sublist(lt, ot, start, count, W, inc_t, dec_t, false), F.ll_append_sublist(lf, of, start, count, W, inc_f, dec_f, false)
		L.decref(ot, dec_t)
		F.decref(of, dec_f)
		return rt_, rf
	end,
	function(lt, lf) -- first / last / get
		if lt[3] > 0 then
			local i = math.random(0, lt[3] - 1)
			check("get", elem_str(F.ll_get_unsafe(lf, i, W)), elem_str(unp(L.ll_get_unsafe(lt, i, W))))
		end
		local ft, ff = L.ll_first(lt, W), F.ll_first(lf, W, mat)
		check("first discriminant", ff[1], ft[1])
		if ft[1] == 1 then check("first element", elem_str(unp(ff[2])), elem_str(unp(ft[2]))) end
		local lt2, lf2 = L.ll_last(lt, W), F.ll_last(lf, W, mat)
		check("last discriminant", lf2[1], lt2[1])
		if lt2[1] == 1 then check("last element", elem_str(unp(lf2[2])), elem_str(unp(lt2[2]))) end
		return lt, lf
	end,
	function(lt, lf) -- split_first / split_last (list in pair field 2)
		if lt[3] == 0 then return lt, lf end
		local first = math.random(2) == 1
		local rt_ = first and L.ll_split_first(lt, W, inc_t, dec_t, false, 2) or L.ll_split_last(lt, W, inc_t, dec_t, false, 2)
		local rf = first and F.ll_split_first(lf, W, inc_f, dec_f, false, 2, mat) or F.ll_split_last(lf, W, inc_f, dec_f, false, 2, mat)
		check("split element", elem_str(unp(rf[2][1])), elem_str(unp(rt_[2][1])))
		dec_t(rt_[2][1])
		dec_f(unp(rf[2][1]))
		return rt_[2][2], rf[2][2]
	end,
	function(lt, lf) -- take / drop at either end
		local which = math.random(4)
		local count = math.random(0, lt[3] + 1)
		if which == 1 then return L.ll_take_first(lt, count, W, dec_t, false), F.ll_take_first(lf, count, W, dec_f, false) end
		if which == 2 then return L.ll_take_last(lt, count, W, dec_t, false), F.ll_take_last(lf, count, W, dec_f, false) end
		if which == 3 then return L.ll_drop_first(lt, W, dec_t, false), F.ll_drop_first(lf, W, dec_f, false) end
		return L.ll_drop_last(lt, W, dec_t, false), F.ll_drop_last(lf, W, dec_f, false)
	end,
	function(lt, lf) -- sort_with (stable: equal first leaves keep their order)
		return L.ll_sort_with(lt, comparator_t, W, inc_t, dec_t, false),
			F.ll_sort_with(lf, comparator_f, W, inc_f, dec_f, false, mat, unp)
	end,
	function(lt, lf) -- map in place when reusable: write each element's first leaf + 1
		if not L.ll_map_can_reuse(lt, true) then return lt, lf end
		check("map_can_reuse", F.ll_map_can_reuse(lf, true), true)
		for i = 0, lt[3] - 1 do
			local t = L.ll_get_unsafe(lt, i, W)
			local a, b, c = F.ll_get_unsafe(lf, i, W)
			L.ll_map_write_unsafe(lt, i, { t[1] + 1, t[2], t[3] }, W)
			F.ll_map_write_unsafe(lf, i, a + 1, b, c, W)
		end
		return lt, lf
	end,
	function(lt, lf) -- reserve
		local spare = math.random(0, 9)
		return L.ll_reserve(lt, spare, W, inc_t, dec_t, false), F.ll_reserve(lf, spare, W, inc_f, dec_f, false)
	end,
}

-- Sharing: incref the current list and keep the alias, so later operations
-- copy instead of updating in place; release aliases at random.
math.randomseed(20261002)
for round = 1, 400 do
	local lt, lf = build(math.random(0, 12))
	local aliases = {}
	for step = 1, 30 do
		if math.random(5) == 1 then
			L.incref(lt, 1, true)
			F.incref(lf, 1, true)
			aliases[#aliases + 1] = { lt, lf }
		end
		if #aliases > 0 and math.random(4) == 1 then
			local a = table.remove(aliases, math.random(#aliases))
			L.decref(a[1], dec_t)
			F.decref(a[2], dec_f)
		end
		local op = math.random(#ops)
		lt, lf = ops[op](lt, lf)
		same_list(("round %d step %d op %d"):format(round, step, op), lt, lf)
		same_rc(("round %d step %d op %d"):format(round, step, op))
	end
	for _, a in ipairs(aliases) do
		same_list(("round %d alias"):format(round), a[1], a[2])
		L.decref(a[1], dec_t)
		F.decref(a[2], dec_f)
	end
	L.decref(lt, dec_t)
	F.decref(lf, dec_f)
	same_rc(("round %d"):format(round))
end

-- Literal and static data: elements given leaf by leaf.
local lit = F.literal(W, { [0] = 1, 1, "a", true, 2, "b", false }, 2)
check("literal length", lit[3], 2)
check("literal elem 1", elem_str(F.get_unsafe(lit, 1)), "2,b,false")
local st = F.static(2, false, { 1, "a", true, 2, "b", false }, W)
check("static unique", L.is_unique(st), false)
check("static elem 0", elem_str(F.get_unsafe(st, 0)), "1,a,true")

if failures == 0 then
	print("list_flat: all passed")
	os.exit(0)
end
print(("list_flat: %d failed"):format(failures))
os.exit(1)
