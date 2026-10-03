-- Roc List for the roc_luajit runtime: a port of src/builtins/list.zig over Lua
-- tables. Capacity, seamless slices and uniqueness follow the builtins exactly,
-- because `List.capacity` and in-place updates make them observable.
--
-- An allocation is { [0] = rc (reference count), [1..] = element slots,
-- cnt = element count recorded for slice teardown, set only when a slice of
-- refcounted elements needs it }; keeping rc in array slot 0 and cnt out of
-- the constructor leaves most allocations without a hash part (80 bytes for
-- one element instead of 128). rc 0 marks static data (never unique,
-- never freed). A list value is the array { [1] = allocation or nil,
-- [2] = 0-based offset of its first element in the allocation, [3] = length,
-- [4] = capacity, [5] = true when it is a seamless slice }; array slots rather
-- than named fields because LuaJIT builds a 4-slot array table in about half
-- the time and two thirds of the memory of a 4-key hash (8 nodes for 5 keys).
-- Comments below still say a/o/n/c/s for these slots. List values are
-- immutable to Roc; operations return new
-- ones, except that a header whose allocation is uniquely owned (rc 1) is
-- updated in place by the operation that consumes it (see with_length).
--
-- Flat element storage: an element whose layout flattens to k >= 2 leaves
-- (LuaEmitter's shapes) is stored as its k leaves, leaf j of the element at
-- 1-based position p in slot (p - 1) * k + j, rather than as one table per
-- element. Offsets, lengths and capacities still count elements. The
-- module below is a template over k, expanded once per stride: `flat(k)`
-- returns the module for stride k (k = 1 is the module this file returns),
-- whose element parameters, results and RC helper calls carry k values.
-- Its macros (`expand_template`):
--   $K          the stride
--   $E(x)       an element held in variables: `x`, or `x_1, ..., x_k`
--   $S(a, X)    the slots of the element at 1-based position X of allocation
--               a: `a[X]`, or `a[(X) * k - (k - 1)], ..., a[(X) * k]`
--   $GET(l, i)  the slots of element i (0-based) of list l, inline
--   $MAT(...)   the element as one table where a whole value is needed (a
--               comparator argument, a Result or pair payload): the value
--               itself for k = 1, else `mat(...)`, the layout's materializer
--   $UNP(x)     the inverse: `x`, or `unp(x)`, the layout's unpacker
--   $R(e)       a returned call: `(e)` (one value), or `e` (all k)
--
-- `w` is the element's native byte width (capacity growth depends on it).
-- `inc(elem, 1)` / `dec(elem)` are the element RC helpers, or nil when the
-- element layout holds no refcounted data (`elements_refcounted == false`).
-- `in_place` is true for UpdateMode.InPlace (ARC's static uniqueness proof).
local TEMPLATE = [==[
return function(crash, ZST, SORT)
	local M = {}
	local floor = math.floor
	local bit = require("bit")
	local tnew = require("table.new")
	local huge = math.huge

	local function empty() return { nil, 0, 0, 0 } end
	M.empty = empty

	-- Zero-width elements never allocate; only the length is observable.
	function M.zst(n) return { nil, 0, n, 0 } end

	local function capacity(l)
		if l[5] then return l[3] end
		return l[4]
	end
	M.capacity = capacity

	-- utils.geometricGrowth and calculateCapacity (integer arithmetic).
	local function geometric_growth(old, w)
		if w == 0 then return old end
		if old == 0 then return (floor(64 / w)) end
		if old < floor(4096 / w) then return old * 2 end
		if old > floor(4096 * 32 / w) then return old * 2 end
		return (floor((old * 3 + 1) / 2))
	end
	local function calculate_capacity(old, requested, w)
		if requested ~= old + 1 then return requested end
		if w == 0 then return requested end
		return (math.max(geometric_growth(old, w), requested))
	end
	M.geometric_growth = geometric_growth

	local function refcount(l)
		if capacity(l) == 0 and not l[5] then return 1 end
		return l[1][0]
	end
	local function is_unique(l) return refcount(l) == 1 end
	M.is_unique = is_unique

	local function is_exclusive(l, in_place)
		if in_place then return true end
		return (is_unique(l))
	end
	local function can_reuse(l, in_place)
		return not l[5] and is_exclusive(l, in_place)
	end

	-- With k > 1 the array part is sized up front: a tag's unused leaves are
	-- nil, and nil written past the array part would leave later slots in
	-- the hash part.
	local function alloc(cap)
		if $K == 1 then return { [0] = 1 } end
		local a = tnew(cap * $K, 0)
		a[0] = 1
		return a
	end

	-- RocList.list_allocate: capacity from calculateCapacity(0, length, w).
	local function list_allocate(length, w)
		if length == 0 then return (empty()) end
		local cap = calculate_capacity(0, length, w)
		return { alloc(cap), 0, length, cap }
	end
	M.allocate = list_allocate
	local function allocate_exact(length)
		if length == 0 then return (empty()) end
		return { alloc(length), 0, length, length }
	end

	local function get(l, i) return $GET(l, i) end -- i is 0-based
	M.get_unsafe = get

	-- Element count a dying allocation tears down (getAllocationElementCount).
	local function allocation_element_count(l, refcounted)
		if l[5] and refcounted then return l[1].cnt or 0 end
		return l[3]
	end

	local function decref_elements(l, dec)
		if l[1] then
			local count = allocation_element_count(l, true)
			local a = l[1]
			for i = 1, count do dec($S(a, i)) end
		end
	end

	-- utils.decref on the allocation: rc 0 (static) is never touched; a list
	-- with no allocation (capacity 0, not a slice) has nothing to release.
	local function release(l)
		local a = l[1]
		if a == nil or (capacity(l) == 0 and not l[5]) then return end
		if a[0] ~= 0 then a[0] = a[0] - 1 end
	end

	-- RocList.decref.
	local function decref(l, dec)
		if dec and is_unique(l) and l[1] then decref_elements(l, dec) end
		release(l)
	end
	M.decref = decref

	-- RocList.incref: record the element count before a list becomes shared.
	function M.incref(l, amount, refcounted)
		if refcounted and can_reuse(l, false) and l[1] then l[1].cnt = l[3] end
		local a = l[1]
		if a == nil or (capacity(l) == 0 and not l[5]) then return end
		if a[0] ~= 0 then a[0] = a[0] + amount end
	end

	local function set_allocation_element_count(l, refcounted)
		if refcounted and not l[5] and l[1] then l[1].cnt = l[3] end
	end

	local function copy_into(dst, dst_start, src, src_start, count)
		-- 0-based element indices relative to each list's first element.
		local da, doff, sa, soff = dst[1], dst[2] + dst_start, src[1], src[2] + src_start
		for i = 1, count do $S(da, doff + i) = $S(sa, soff + i) end
	end

	-- RocList.makeUnique.
	local function make_unique(l, w, inc, dec)
		if is_unique(l) then return l end
		if l[3] == 0 then
			decref(l, dec)
			return (empty())
		end
		local new = list_allocate(l[3], w)
		copy_into(new, 0, l, 0, l[3])
		if inc then
			for i = 0, l[3] - 1 do inc($GET(new, i), 1) end
		end
		decref(l, dec)
		return new
	end
	M.make_unique = make_unique

	-- decrefAfterMovingSliceElements.
	local function decref_after_moving_slice(l, dec)
		if dec then
			local moved_start = l[2]
			local moved_end = moved_start + l[3]
			local count = allocation_element_count(l, true)
			local a = l[1]
			for i = 0, moved_start - 1 do dec($S(a, i + 1)) end
			for i = moved_end, count - 1 do dec($S(a, i + 1)) end
		end
		release(l)
	end

	-- RocList.reallocateFresh.
	local function reallocate_fresh(l, new_length, w, inc, dec)
		local old_length = l[3]
		local result = list_allocate(new_length, w)
		local move = l[5] and is_unique(l)
		if l[1] then
			copy_into(result, 0, l, 0, old_length)
			if inc and not move then
				for i = 0, old_length - 1 do inc($GET(result, i), 1) end
			end
		end
		if move then decref_after_moving_slice(l, dec) else decref(l, dec) end
		return result
	end

	-- RocList.reallocate.
	local function reallocate(l, new_length, w, inc, dec, in_place)
		if l[1] then
			if can_reuse(l, in_place) then
				local cap = l[4]
				if cap >= new_length then
					return { l[1], 0, new_length, cap }
				end
				return { l[1], 0, new_length, calculate_capacity(cap, new_length, w) }
			end
			return (reallocate_fresh(l, new_length, w, inc, dec))
		end
		return (list_allocate(new_length, w))
	end

	-- The list value l with length n, updated in place when l's allocation is
	-- uniquely owned (rc 1: no other value refers to it, hence none to this
	-- header). That removes a table allocation from each append, sublist and
	-- drop. Every caller consumes l and passes either a fresh header or one it
	-- proved exclusive; the rc test keeps the update sound locally should a
	-- caller ever pass anything else, since headers without an allocation
	-- (empty and zero-sized lists) may be shared and static data has rc 0.
	-- Callers must not read l's old fields after the call.
	local function with_length(l, n)
		local a = l[1]
		if a and a[0] == 1 then
			l[3] = n
			return l
		end
		return { a, l[2], n, l[4], l[5] }
	end

	-- listReserve.
	local function reserve(l, spare, w, inc, dec, in_place)
		local original_len = l[3]
		local cap = capacity(l)
		if is_exclusive(l, in_place) and spare <= cap - original_len then return l end
		local out = reallocate(l, original_len + spare, w, inc, dec, in_place)
		return (with_length(out, original_len))
	end
	M.reserve = reserve

	-- listReserveForAppend.
	local function reserve_for_append(l, spare, w, inc, dec, in_place)
		local original_len = l[3]
		local cap = capacity(l)
		if is_exclusive(l, in_place) and spare <= cap - original_len then return l end
		local needed = original_len + spare
		local base = can_reuse(l, in_place) and cap or original_len
		local desired = math.max(needed, geometric_growth(base, w))
		local out = reallocate(l, desired, w, inc, dec, in_place)
		return (with_length(out, original_len))
	end

	function M.with_capacity(cap, w)
		return (reserve(empty(), cap, w, nil, nil, true))
	end

	-- listAppendUnsafe: the caller proved a unique allocation with a spare slot.
	function M.append_unsafe(l, $E(elem))
		local n = l[3]
		local out = with_length(l, n + 1)
		local a, p = out[1], out[2] + n + 1
		$S(a, p) = $E(elem)
		return out
	end

	-- listAppend (reserve one, then append).
	function M.append(l, $E(elem), w, inc, dec, in_place)
		local out = reserve(l, 1, w, inc, dec, in_place)
		out = with_length(out, out[3] + 1)
		local a, p = out[1], out[2] + out[3]
		$S(a, p) = $E(elem)
		return out
	end

	-- listPrepend.
	function M.prepend(l, $E(elem), w, inc, dec, in_place)
		local old_length = l[3]
		local out = reserve(l, 1, w, inc, dec, in_place)
		out = with_length(out, out[3] + 1)
		local a, o = out[1], out[2]
		for i = old_length, 1, -1 do $S(a, o + i + 1) = $S(a, o + i) end
		$S(a, o + 1) = $E(elem)
		return out
	end

	-- listConcat.
	function M.concat(la, lb, w, inc, dec, in_place_a, in_place_b)
		if la[3] == 0 then
			if lb[3] == 0 then
				decref(lb, dec)
				return (make_unique(la, w, inc, dec))
			end
			decref(la, dec)
			return (make_unique(lb, w, inc, dec))
		elseif lb[3] == 0 then
			decref(lb, dec)
			return (make_unique(la, w, inc, dec))
		end
		local same = la[1] ~= nil and la[1] == lb[1]
		local consume_a = not same and is_exclusive(la, in_place_a)
		local consume_b = not same and is_exclusive(lb, in_place_b)
		local reuse_a = not same and can_reuse(la, in_place_a)
		local reuse_b = not same and can_reuse(lb, in_place_b)
		local use_a = reuse_a or (consume_a and not reuse_b)
		local total = la[3] + lb[3]
		if use_a then
			local out = reallocate(la, total, w, inc, dec, in_place_a)
			copy_into(out, la[3], lb, 0, lb[3])
			if inc then
				for i = 0, lb[3] - 1 do inc($GET(lb, i), 1) end
			end
			decref(lb, dec)
			return out
		elseif consume_b then
			local nb = lb[3]
			local out = reallocate(lb, total, w, inc, dec, in_place_b)
			local a, o = out[1], out[2]
			for i = nb, 1, -1 do $S(a, o + la[3] + i) = $S(a, o + i) end
			copy_into(out, 0, la, 0, la[3])
			if inc then
				for i = 0, la[3] - 1 do inc($GET(la, i), 1) end
			end
			decref(la, dec)
			return out
		end
		local out = list_allocate(total, w)
		copy_into(out, 0, la, 0, la[3])
		copy_into(out, la[3], lb, 0, lb[3])
		if inc then
			for i = 0, la[3] - 1 do inc($GET(la, i), 1) end
			for i = 0, lb[3] - 1 do inc($GET(lb, i), 1) end
		end
		decref(la, dec)
		decref(lb, dec)
		return out
	end

	local function slice_of(l, start, keep_len)
		-- The slice shares l's allocation; offsets are relative to it.
		return { l[1], l[2] + start, keep_len, 0, true }
	end

	-- listSublist.
	function M.sublist(l, start, len, dec, in_place)
		local size = l[3]
		local reuse = can_reuse(l, in_place)
		if size == 0 or len == 0 or start >= size then
			if reuse then
				if l[1] and dec then
					for i = 0, size - 1 do dec($GET(l, i)) end
				end
				return (with_length(l, 0))
			end
			decref(l, dec)
			return (empty())
		end
		if l[1] then
			local keep_len = math.min(len, size - start)
			if start == 0 and reuse then
				if dec then
					for i = start + keep_len, size - 1 do dec($GET(l, i)) end
				end
				return (with_length(l, keep_len))
			end
			if reuse then set_allocation_element_count(l, dec ~= nil) end
			return (slice_of(l, start, keep_len))
		end
		return (empty())
	end

	-- listSublistBorrowed.
	function M.sublist_borrowed(l, start, len, refcounted)
		local size = l[3]
		if size == 0 or len == 0 or start >= size then return (empty()) end
		if not l[1] then return (empty()) end
		local keep_len = math.min(len, size - start)
		if refcounted and can_reuse(l, false) then set_allocation_element_count(l, true) end
		return (slice_of(l, start, keep_len))
	end

	-- listDropAt.
	function M.drop_at(l, index, w, inc, dec, in_place)
		local size = l[3]
		if size == 0 then
			decref(l, dec)
			return (empty())
		end
		if index >= size then return l end
		if size == 1 then
			decref(l, dec)
			return (empty())
		end
		if index == 0 then return (M.sublist(l, 1, size - 1, dec, in_place)) end
		if index == size - 1 then return (M.sublist(l, 0, size - 1, dec, in_place)) end
		if not l[1] then return (empty()) end
		if can_reuse(l, in_place) then
			if dec then dec($GET(l, index)) end
			local a, o = l[1], l[2]
			for i = index + 1, size - 1 do $S(a, o + i) = $S(a, o + i + 1) end
			return (with_length(l, size - 1))
		end
		local out = list_allocate(size - 1, w)
		copy_into(out, 0, l, 0, index)
		copy_into(out, index, l, index + 1, size - index - 1)
		if inc then
			for i = 0, out[3] - 1 do inc($GET(out, i), 1) end
		end
		decref(l, dec)
		return out
	end

	local function swap(l, i, j)
		local a, o = l[1], l[2]
		$S(a, o + i + 1), $S(a, o + j + 1) = $S(a, o + j + 1), $S(a, o + i + 1)
	end

	-- listSwap.
	function M.swap(l, i, j, w, inc, dec, in_place)
		if i == j then return l end
		local size = l[3]
		if i >= size or j >= size then return l end
		local out = in_place and l or make_unique(l, w, inc, dec)
		swap(out, i, j)
		return out
	end

	-- listReverse.
	function M.reverse(l, w, inc, dec, in_place)
		if l[3] <= 1 then return l end
		local out = in_place and l or make_unique(l, w, inc, dec)
		local lo, hi = 0, out[3] - 1
		while lo < hi do
			swap(out, lo, hi)
			lo, hi = lo + 1, hi - 1
		end
		return out
	end

	-- listReplaceInPlace / listReplace: returns the list and the old element.
	function M.replace(l, index, $E(elem), w, inc, dec, in_place)
		local out = in_place and l or make_unique(l, w, inc, dec)
		local a, slot = out[1], out[2] + index + 1
		local $E(old) = $S(a, slot)
		$S(a, slot) = $E(elem)
		return out, $E(old)
	end

	-- listReleaseExcessCapacity.
	function M.release_excess_capacity(l, w, inc, dec, in_place)
		local old_length = l[3]
		if can_reuse(l, in_place) and capacity(l) == old_length then return l end
		if old_length == 0 then
			decref(l, dec)
			return (empty())
		end
		local out = allocate_exact(old_length)
		if l[1] then
			copy_into(out, 0, l, 0, old_length)
			if inc then
				for i = 0, old_length - 1 do inc($GET(l, i), 1) end
			end
		end
		decref(l, dec)
		return out
	end

	-- listAppendRangeWithin: scratch slop as the builtin reserves it.
	local append_range_within_scratch_bytes = 40
	local function append_range_within_core(out, start, count, inc)
		local original_len = out[3]
		local a, o = out[1], out[2]
		for i = 0, count - 1 do $S(a, o + original_len + i + 1) = $S(a, o + start + i + 1) end
		if inc then
			for i = 0, count - 1 do inc($S(a, o + original_len + i + 1), 1) end
		end
		return (with_length(out, original_len + count))
	end
	function M.append_range_within(l, start, count, w, inc, dec, in_place)
		local slop = floor((append_range_within_scratch_bytes + w - 1) / w)
		local out = reserve_for_append(l, count + slop, w, inc, dec, in_place)
		return (append_range_within_core(out, start, count, inc))
	end
	function M.append_range_within_unsafe(l, start, count, inc)
		return (append_range_within_core(l, start, count, inc))
	end

	-- listCopyRangeWithin.
	function M.copy_range_within(l, dest, src, count, w, inc, dec)
		if count == 0 or w == 0 or dest == src then return l end
		local out = make_unique(l, w, inc, dec)
		local a, o = out[1], out[2]
		if inc then
			for i = 0, count - 1 do inc($S(a, o + src + i + 1), 1) end
			for i = 0, count - 1 do dec($S(a, o + dest + i + 1)) end
		end
		local tmp = {}
		for i = 1, count do $S(tmp, i) = $S(a, o + src + i) end
		for i = 1, count do $S(a, o + dest + i) = $S(tmp, i) end
		return out
	end

	-- listAppendSublist: src is borrowed.
	function M.append_sublist(l, src, start, len, w, inc, dec, in_place)
		local count = len
		if count == 0 then return l end
		local original_len = l[3]
		local out = reserve_for_append(l, count, w, inc, dec, in_place)
		local src_list = (src[1] == l[1] and src[2] == l[2]) and out or src
		local a, o = out[1], out[2]
		for i = 0, count - 1 do $S(a, o + original_len + i + 1) = $GET(src_list, start + i) end
		if inc then
			for i = 0, count - 1 do inc($S(a, o + original_len + i + 1), 1) end
		end
		return (with_length(out, original_len + count))
	end

	-- listAppendLeBytes on a List(U8): bytes are Lua numbers (stride 1 only).
	function M.append_le_bytes(l, value, count, in_place)
		if count == 0 then return l end
		local original_len = l[3]
		local out
		if not l[5] and capacity(l) >= original_len + 8 and is_exclusive(l, in_place) and l[1] then
			out = l
		else
			out = reserve_for_append(l, count, 1, nil, nil, in_place)
		end
		local a, o = out[1], out[2]
		local word = value
		for i = 0, count - 1 do
			a[o + original_len + i + 1] = tonumber(bit.band(word, 0xff))
			word = bit.rshift(word, 8)
		end
		return (with_length(out, original_len + count))
	end

	function M.owned_unique(l)
		if l[5] or not l[1] then return 0 end
		if not is_unique(l) then return 0 end
		return 1
	end

	function M.slack_unique(l)
		if l[5] then return 0 end
		if not is_unique(l) then return 0 end
		return capacity(l) - l[3]
	end

	function M.map_can_reuse(l) return (can_reuse(l, false)) end

	-- A list literal: an exact-capacity allocation holding the elements
	-- (evalListLiteral). Zero-width elements and empty literals do not allocate.
	-- A static byte-list literal (makeStaticRocListLiteralView): refcount 0,
	-- never unique. With no bytes the header records the length as its
	-- capacity; a view of part of its backing is a seamless slice. `a` holds
	-- the n elements' slots (k per element).
	function M.static(n, slice, a, w)
		if n == 0 or w == 0 then return { nil, 0, n, n } end
		a[0] = 0
		if slice then return { a, 0, n, 0, true } end
		return { a, 0, n, n }
	end

	-- `a` is a fresh table constructor of the n elements' slots (no register limit).
	function M.literal(w, a, n)
		if n == 0 or w == 0 then return (M.zst(n)) end
		a[0] = 1
		return { a, 0, n, n }
	end

	-- LIR low-level entry points --------------------------------------------------
	-- One per interpreter case (src/eval/interpreter.zig), including its
	-- zero-width shortcuts. U64 arguments arrive as numbers or uint64 cdata
	-- (runtime.lua, "64-bit integers"); lengths and capacities return as
	-- numbers. Elements with k > 1 cannot be zero-width.

	local function num(x) return (tonumber(x)) end

	-- zstSublistLen.
	local function zst_sublist_len(size, start, len)
		if size == 0 or len == 0 or start >= size then return 0 end
		return (math.min(len, size - start))
	end

	function M.ll_len(l) return l[3] end
	function M.ll_capacity(l) return (capacity(l)) end
	function M.ll_slack_unique(l) return (M.slack_unique(l)) end
	function M.ll_owned_unique(l) return (M.owned_unique(l)) end

	function M.ll_get_unsafe(l, i, w)
		if w == 0 or not l[1] then return ZST end
		return $R(get(l, num(i)))
	end

	function M.ll_append_unsafe(l, $E(e), w)
		if w == 0 then return (M.zst(l[3] + 1)) end
		return (M.append_unsafe(l, $E(e)))
	end

	function M.ll_concat(a, b, w, inc, dec, ip_a, ip_b)
		if w == 0 then return (M.zst(a[3] + b[3])) end
		return (M.concat(a, b, w, inc, dec, ip_a, ip_b))
	end

	function M.ll_append_range_within(l, start, count, w, inc, dec, ip)
		count = num(count)
		if w == 0 then return (M.zst(l[3] + count)) end
		if count == 0 then return l end
		return (M.append_range_within(l, num(start), count, w, inc, dec, ip))
	end

	function M.ll_copy_range_within(l, dest, src, count, w, inc, dec)
		count = num(count)
		if w == 0 or count == 0 then return l end
		return (M.copy_range_within(l, num(dest), num(src), count, w, inc, dec))
	end

	function M.ll_append_range_within_unsafe(l, start, count, w, inc)
		count = num(count)
		if w == 0 then return (M.zst(l[3] + count)) end
		if count == 0 then return l end
		return (M.append_range_within_unsafe(l, num(start), count, inc))
	end

	function M.ll_append_le_bytes(l, value, count, ip)
		return (M.append_le_bytes(l, value, num(count), ip))
	end

	function M.ll_append_sublist(l, src, start, count, w, inc, dec, ip)
		count = num(count)
		if w == 0 then return (M.zst(l[3] + count)) end
		return (M.append_sublist(l, src, num(start), count, w, inc, dec, ip))
	end

	function M.ll_prepend(l, $E(e), w, inc, dec, ip)
		if w == 0 then return (M.zst(l[3] + 1)) end
		return (M.prepend(l, $E(e), w, inc, dec, ip))
	end

	function M.ll_swap(l, i, j, w, inc, dec, ip)
		if w == 0 then return (M.zst(l[3])) end
		return (M.swap(l, num(i), num(j), w, inc, dec, ip))
	end

	function M.ll_map_can_reuse(l, interchangeable)
		if not interchangeable then return false end
		return (can_reuse(l, false))
	end

	function M.ll_map_write_unsafe(l, i, $E(v), w)
		if w == 0 then return l end
		local a, p = l[1], l[2] + num(i) + 1
		$S(a, p) = $E(v)
		return l
	end

	-- `rec` is the { len, start } record: semantic fields len (1), start (2).
	function M.ll_sublist(l, rec, w, dec, ip)
		local start, len = num(rec[2]), num(rec[1])
		if w == 0 then return (M.zst(zst_sublist_len(l[3], start, len))) end
		return (M.sublist(l, start, len, dec, ip))
	end
	function M.ll_sublist_borrowed(l, rec, w, refcounted)
		local start, len = num(rec[2]), num(rec[1])
		if w == 0 then return (M.zst(zst_sublist_len(l[3], start, len))) end
		return (M.sublist_borrowed(l, start, len, refcounted))
	end

	function M.ll_drop_at(l, index, w, inc, dec, ip)
		index = num(index)
		if w == 0 then
			local n = l[3]
			return (M.zst(index >= n and n or math.max(n - 1, 0)))
		end
		return (M.drop_at(l, index, w, inc, dec, ip))
	end

	-- list_replace_unsafe: returns (list, old element); the emitter builds the
	-- result record.
	function M.ll_replace(l, i, $E(v), w, inc, dec, ip)
		if w == 0 then return M.zst(l[3]), ZST end
		return M.replace(l, num(i), $E(v), w, inc, dec, ip)
	end

	-- list_set / list_set_in_place_unsafe: replace, then release the old element.
	function M.ll_set(l, i, $E(v), w, inc, dec, ip)
		if w == 0 then return (M.zst(l[3])) end
		local out, $E(old) = M.replace(l, num(i), $E(v), w, inc, dec, ip)
		if dec then dec($E(old)) end
		return out
	end

	function M.ll_with_capacity(cap, w)
		if w == 0 then return (M.zst(0)) end
		return (M.with_capacity(num(cap), w))
	end

	function M.ll_reserve(l, spare, w, inc, dec, ip)
		if w == 0 then return (M.zst(l[3])) end
		return (reserve(l, num(spare), w, inc, dec, ip))
	end

	function M.ll_release_excess_capacity(l, w, inc, dec, ip)
		if w == 0 then return (M.zst(l[3])) end
		return (M.release_excess_capacity(l, w, inc, dec, ip))
	end

	-- list_first / list_last: Ok (discriminant 1) with the element, else Err (0).
	function M.ll_first(l, w, mat)
		if l[3] > 0 and w == 0 then return { 1, ZST } end
		if l[3] > 0 and l[1] then return { 1, $MAT($GET(l, 0)) } end
		return { 0 }
	end
	function M.ll_last(l, w, mat)
		if l[3] > 0 and w == 0 then return { 1, ZST } end
		if l[3] > 0 and l[1] then return { 1, $MAT($GET(l, l[3] - 1)) } end
		return { 0 }
	end

	local U64_MAX = 18446744073709551615

	function M.ll_drop_first(l, w, dec, ip)
		if w == 0 then return (M.zst(zst_sublist_len(l[3], 1, U64_MAX))) end
		return (M.sublist(l, 1, U64_MAX, dec, ip))
	end
	function M.ll_drop_last(l, w, dec, ip)
		local len = l[3]
		if w == 0 then return (M.zst(len == 0 and 0 or len - 1)) end
		if len == 0 then return l end
		return (M.sublist(l, 0, len - 1, dec, ip))
	end
	function M.ll_take_first(l, count, w, dec, ip)
		count = num(count)
		if w == 0 then return (M.zst(zst_sublist_len(l[3], 0, count))) end
		return (M.sublist(l, 0, count, dec, ip))
	end
	function M.ll_take_last(l, count, w, dec, ip)
		count = num(count)
		local len = l[3]
		local start = count >= len and 0 or len - count
		if w == 0 then return (M.zst(zst_sublist_len(len, start, count))) end
		return (M.sublist(l, start, count, dec, ip))
	end

	function M.ll_reverse(l, w, inc, dec, ip)
		if w == 0 then return (M.zst(l[3])) end
		return (M.reverse(l, w, inc, dec, ip))
	end

	-- list_sort_with (listSortWith): stable fluxsort through the erased
	-- comparator, which consumes both arguments, so each is increfed first
	-- (compareErasedCallable). Builtin.roc types the comparator's result as
	-- [After, Before, Same], whose discriminant 0 is After. The comparator
	-- takes whole values, so flat elements are sorted as materialized tables.
	function M.ll_sort_with(l, c, w, inc, dec, ip, mat, unp)
		if w == 0 then return (M.zst(l[3])) end
		if l[3] < 2 then return l end
		local r = ip and l or make_unique(l, w, inc, dec)
		local a, o, n = r[1], r[2], r[3]
		local mem = {}
		for i = 1, n do mem[i] = $MAT($S(a, o + i)) end
		local proc, cap = c.proc, c.cap
		SORT.fluxsort(mem, n, function(x, y)
			if inc then
				-- Unpacked into locals first: a call in a non-final argument
				-- position would pass only its first value.
				local $E(xe) = $UNP(x)
				inc($E(xe), 1)
				local $E(ye) = $UNP(y)
				inc($E(ye), 1)
			end
			return proc(x, y, cap, nil)[1] == 0
		end)
		for i = 1, n do $S(a, o + i) = $UNP(mem[i]) end
		return r
	end

	-- list_split_first / list_split_last: Ok holds the { elem, rest } pair;
	-- `list_pos` is the pair field (1 or 2) that holds the list.
	local function pair(elem, rest, list_pos)
		if list_pos == 1 then return { rest, elem } end
		return { elem, rest }
	end
	function M.ll_split_first(l, w, inc, dec, ip, list_pos, mat)
		if l[3] > 0 and w == 0 then return { 1, pair(ZST, M.zst(l[3] - 1), list_pos) } end
		if l[3] > 0 and l[1] then
			local $E(first) = $GET(l, 0)
			if inc then inc($E(first), 1) end
			return { 1, pair($MAT($E(first)), M.sublist(l, 1, U64_MAX, dec, ip), list_pos) }
		end
		return { 0 }
	end
	function M.ll_split_last(l, w, inc, dec, ip, list_pos, mat)
		if l[3] > 0 and w == 0 then return { 1, pair(ZST, M.zst(l[3] - 1), list_pos) } end
		if l[3] > 0 and l[1] then
			local $E(last) = $GET(l, l[3] - 1)
			if inc then inc($E(last), 1) end
			return { 1, pair($MAT($E(last)), M.sublist(l, 0, l[3] - 1, dec, ip), list_pos) }
		end
		return { 0 }
	end

	-- RC entry points used by the generated helpers.
	function M.free(l, dec)
		if dec and l[1] then decref_elements(l, dec) end
	end

	M.huge = huge
	M.crash = crash
	return M
end
]==]

-- Expand the template's macros for stride k (see the header). `%b()` finds
-- each macro's balanced argument list; arguments split at commas outside
-- (), [] and {}, and are expanded before the macro that contains them.
local function split_args(inner)
	local list, depth, start = {}, 0, 1
	for q = 1, #inner do
		local c = inner:byte(q)
		if c == 40 or c == 91 or c == 123 then -- ( [ {
			depth = depth + 1
		elseif c == 41 or c == 93 or c == 125 then -- ) ] }
			depth = depth - 1
		elseif c == 44 and depth == 0 then -- ,
			list[#list + 1] = inner:sub(start, q - 1):match("^%s*(.-)%s*$")
			start = q + 1
		end
	end
	list[#list + 1] = inner:sub(start):match("^%s*(.-)%s*$")
	return list
end

local expand_template
local function slots(a, x, k)
	if k == 1 then return a .. "[" .. x .. "]" end
	local parts = {}
	for j = 1, k do
		local off = k - j
		parts[j] = ("%s[(%s) * %d%s]"):format(a, x, k, off == 0 and "" or " - " .. off)
	end
	return (table.concat(parts, ", "))
end
local macros = {
	E = function(a, k)
		if k == 1 then return a[1] end
		local parts = {}
		for j = 1, k do parts[j] = a[1] .. "_" .. j end
		return (table.concat(parts, ", "))
	end,
	S = function(a, k) return (slots(a[1], a[2], k)) end,
	GET = function(a, k) return (slots(a[1] .. "[1]", a[1] .. "[2] + (" .. a[2] .. ") + 1", k)) end,
	MAT = function(a, k)
		local all = table.concat(a, ", ")
		return k == 1 and all or "mat(" .. all .. ")"
	end,
	UNP = function(a, k) return k == 1 and a[1] or "unp(" .. a[1] .. ")" end,
	R = function(a, k) return k == 1 and "(" .. a[1] .. ")" or a[1] end,
}
function expand_template(src, k)
	local out, i = {}, 1
	while true do
		-- A plain search for "$" (memchr speed); patterns only at each hit.
		local s = src:find("$", i, true)
		if not s then
			out[#out + 1] = src:sub(i)
			return (table.concat(out))
		end
		out[#out + 1] = src:sub(i, s - 1)
		local name = src:match("^%u+", s + 1)
		if name == "K" then
			out[#out + 1] = tostring(k)
			i = s + 2
		else
			local m = macros[name]
			if not m then error("unknown macro $" .. tostring(name)) end
			local p = s + 1 + #name
			local e = select(2, src:find("^%b()", p))
			if not e then error("macro $" .. name .. " without balanced arguments") end
			local a = split_args(src:sub(p + 1, e - 1))
			for j = 1, #a do
				if a[j]:find("$", 1, true) then a[j] = expand_template(a[j], k) end
			end
			out[#out + 1] = m(a, k)
			i = e + 1
		end
	end
end


return function(crash, ZST, SORT)
	local by_stride = {}
	local function flat(k)
		local m = by_stride[k]
		if m then return m end
		local chunk = assert(load(expand_template(TEMPLATE, k), "=list.lua (stride " .. k .. ")"))
		m = chunk()(crash, ZST, SORT)
		m.flat = flat
		m.expand_template = expand_template
		by_stride[k] = m
		return m
	end
	return flat(1)
end
