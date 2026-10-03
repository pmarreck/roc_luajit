-- Fluxsort for the roc_luajit runtime: a port of src/builtins/sort.zig that
-- performs the same comparisons in the same order, so a comparator that
-- contradicts itself (or crashes, or prints with dbg) behaves as it does under
-- Roc. Byte pointers become integer indices into one flat table `m`: the array
-- occupies m[1..len] and scratch buffers (the Zig heap and stack buffers) are
-- carved above it, so pointer arithmetic and pointer comparisons carry over in
-- element units. Element width only selects direct versus pointer-indirect
-- sorting in sort.zig, which is the same algorithm, so it does not appear here.
--
-- One deliberate difference: median_of_cube_root derives its sample offset from
-- a stack address (`@intFromPtr(&div) / 16 % div`), so native Roc does not fix
-- it; this port uses offset 0. It only matters for partitions over 2048
-- elements under a comparator that is not a total preorder.
local floor = math.floor
local bxor = require("bit").bxor

local QUAD_CACHE = 262144
local FLUX_OUT = 96

-- Current sort: memory, "a after b" predicate on values, scratch stack top.
-- Saved and restored around each sort so a comparator may sort recursively.
local m, after, stk

local function gt(x, y) return (after(m[x], m[y])) end

local function alloc(k)
	local b = stk
	stk = stk + k
	return b
end

local function mcpy(d, s, n)
	for i = 0, n - 1 do m[d + i] = m[s + i] end
end
local function copy_backwards(d, s, n)
	for i = n - 1, 0, -1 do m[d + i] = m[s + i] end
end

-- Primitives ------------------------------------------------------------------

local function swap_branchless_return_gt(p)
	if gt(p, p + 1) then
		local tmp = m[p]
		m[p] = m[p + 1]
		m[p + 1] = tmp
		return 1
	end
	return 0
end
local swap_branchless = swap_branchless_return_gt

local function head_branchless_merge(d, l, r)
	if not gt(l, r) then
		m[d] = m[l]
		l = l + 1
	else
		m[d] = m[r]
		r = r + 1
	end
	return d + 1, l, r
end

local function tail_branchless_merge(d, l, r)
	if gt(l, r) then
		m[d] = m[l]
		l = l - 1
	else
		m[d] = m[r]
		r = r - 1
	end
	return d - 1, l, r
end

-- head_guarded_merge / tail_guarded_merge: never take from a spent run; the
-- comparison still happens (against the live run itself) as in sort.zig.
local function head_guarded_merge(d, l, r, la, ra)
	local lte = not gt(la and l or r, ra and r or l)
	local take_left
	if not ra then take_left = true elseif not la then take_left = false else take_left = lte end
	if take_left then
		m[d] = m[l]
		l = l + 1
	else
		m[d] = m[r]
		r = r + 1
	end
	return d + 1, l, r, take_left
end

local function tail_guarded_merge(d, l, r, la, ra)
	local g = gt(la and l or r, ra and r or l)
	local take_left
	if not ra then take_left = true elseif not la then take_left = false else take_left = g end
	if take_left then
		m[d] = m[l]
		l = l - 1
	else
		m[d] = m[r]
		r = r - 1
	end
	return d - 1, l, r, take_left
end

local function parity_merge_two(dest, arr)
	local lrem, rrem = 2, 2
	local l, r, d, tl = arr, arr + 2, dest, nil
	for _ = 1, 2 do
		d, l, r, tl = head_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
	l, r, d = arr + 1, arr + 3, dest + 3
	for _ = 1, 2 do
		d, l, r, tl = tail_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
end

local function parity_merge_four(dest, arr)
	local lrem, rrem = 4, 4
	local l, r, d, tl = arr, arr + 4, dest, nil
	for _ = 1, 4 do
		d, l, r, tl = head_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
	l, r, d = arr + 3, arr + 7, dest + 7
	for _ = 1, 4 do
		d, l, r, tl = tail_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
end

-- Merges -----------------------------------------------------------------------

-- Merge two neighboring sorted runs whose lengths differ by at most one; the
-- remaining-counts keep it a permutation under any comparator.
local function parity_merge(dest, src, left_len, right_len)
	local lh, rh, dh = src, src + left_len, dest
	local lt = rh - 1
	local rt = lt + right_len
	local dt = dest + left_len + right_len - 1
	local lrem, rrem = left_len, right_len
	local total = left_len + right_len
	local head_steps = left_len < right_len and left_len + 1 or left_len
	local tail_steps = total - head_steps
	local tl
	if left_len < right_len then
		dh, lh, rh, tl = head_guarded_merge(dh, lh, rh, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
	dh, lh, rh, tl = head_guarded_merge(dh, lh, rh, lrem ~= 0, rrem ~= 0)
	if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	for _ = 1, left_len - 1 do
		dh, lh, rh, tl = head_guarded_merge(dh, lh, rh, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
		if tail_steps > 0 then
			tail_steps = tail_steps - 1
			dt, lt, rt, tl = tail_guarded_merge(dt, lt, rt, lrem ~= 0, rrem ~= 0)
			if tl then lrem = lrem - 1 else rrem = rrem - 1 end
		end
	end
	if tail_steps > 0 then
		dt, lt, rt, tl = tail_guarded_merge(dt, lt, rt, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
end

-- Merge two runs in chunks of 8 where possible, then pairwise.
local function cross_merge(dest, src, left_len, right_len)
	local lh = src
	local rh = src + left_len
	local lt = rh - 1
	local rt = lt + right_len

	if left_len + 1 >= right_len and right_len + 1 >= left_len and left_len >= 32 then
		if gt(lh + 15, rh) and not gt(lh, rh + 15) and gt(lt, rt - 15) and not gt(lt - 15, rt) then
			parity_merge(dest, src, left_len, right_len)
			return
		end
	end

	local dh = dest
	local dt = dest + left_len + right_len - 1

	while true do
		local again = false
		if lt - lh > 8 then
			while not gt(lh + 7, rh) do
				for _ = 1, 8 do
					m[dh] = m[lh]
					dh = dh + 1
					lh = lh + 1
				end
				if lt - lh <= 8 then again = true break end
			end
			if not again then
				while gt(lt - 7, rt) do
					for _ = 1, 8 do
						m[dt] = m[lt]
						dt = dt - 1
						lt = lt - 1
					end
					if lt - lh <= 8 then again = true break end
				end
			end
		end
		if not again and rt - rh > 8 then
			while gt(lh, rh + 7) do
				for _ = 1, 8 do
					m[dh] = m[rh]
					dh = dh + 1
					rh = rh + 1
				end
				if rt - rh <= 8 then again = true break end
			end
			if not again then
				while not gt(lt, rt - 7) do
					for _ = 1, 8 do
						m[dt] = m[rt]
						dt = dt - 1
						rt = rt - 1
					end
					if rt - rh <= 8 then again = true break end
				end
			end
		end
		if not again then
			if dh > dt or dt - dh < 16 then break end
			for _ = 1, 8 do
				if lh > lt and rh > rt then break end
				dh, lh, rh = head_guarded_merge(dh, lh, rh, lh <= lt, rh <= rt)
				if lh > lt and rh > rt then break end
				dt, lt, rt = tail_guarded_merge(dt, lt, rt, lh <= lt, rh <= rt)
			end
		end
	end

	while lh <= lt and rh <= rt do
		dh, lh, rh = head_branchless_merge(dh, lh, rh)
	end
	while lh <= lt do
		m[dh] = m[lh]
		dh = dh + 1
		lh = lh + 1
	end
	while rh <= rt do
		m[dh] = m[rh]
		dh = dh + 1
		rh = rh + 1
	end
end

-- partial_forward_merge_right_tail_2 / _left_tail_2, as one loop over `side`.
local function backward_merge_2(right_side, d, lhead, lt, rhead, rt)
	while true do
		if right_side then
			if not gt(lt, rt - 1) then
				for _ = 1, 2 do
					m[d] = m[rt]
					d = d - 1
					rt = rt - 1
				end
				if not (rt > rhead + 1) then return d, lt, rt, true end
			elseif gt(lt - 1, rt) then
				for _ = 1, 2 do
					m[d] = m[lt]
					d = d - 1
					lt = lt - 1
				end
				if not (lt > lhead + 1) then return d, lt, rt, true end
				right_side = false
			else
				return d, lt, rt, false
			end
		else
			if gt(lt - 1, rt) then
				for _ = 1, 2 do
					m[d] = m[lt]
					d = d - 1
					lt = lt - 1
				end
				if not (lt > lhead + 1) then return d, lt, rt, true end
			elseif not gt(lt, rt - 1) then
				for _ = 1, 2 do
					m[d] = m[rt]
					d = d - 1
					rt = rt - 1
				end
				if not (rt > rhead + 1) then return d, lt, rt, true end
				right_side = true
			else
				return d, lt, rt, false
			end
		end
	end
end

-- partial_forward_merge_right_head_2 / _left_head_2, as one loop over `side`.
local function forward_merge_2(right_side, d, lh, lt, rh, rt)
	while true do
		if right_side then
			if gt(lh, rh + 1) then
				for _ = 1, 2 do
					m[d] = m[rh]
					d = d + 1
					rh = rh + 1
				end
				if not (rh < rt - 1) then return d, lh, rh, true end
			elseif not gt(lh + 1, rh) then
				for _ = 1, 2 do
					m[d] = m[lh]
					d = d + 1
					lh = lh + 1
				end
				if not (lh < lt - 1) then return d, lh, rh, true end
				right_side = false
			else
				return d, lh, rh, false
			end
		else
			if not gt(lh + 1, rh) then
				for _ = 1, 2 do
					m[d] = m[lh]
					d = d + 1
					lh = lh + 1
				end
				if not (lh < lt - 1) then return d, lh, rh, true end
			elseif gt(lh, rh + 1) then
				for _ = 1, 2 do
					m[d] = m[rh]
					d = d + 1
					rh = rh + 1
				end
				if not (rh < rt - 1) then return d, lh, rh, true end
				right_side = true
			else
				return d, lh, rh, false
			end
		end
	end
end

-- Merge a full left block with a shorter right chunk, tail to head.
local function partial_backwards_merge(arr, len, swap, swap_len, block_len)
	if len == block_len then return end
	local lt = arr + block_len - 1
	local dt = arr + len - 1
	if not gt(lt, lt + 1) then return end

	local right_len = len - block_len
	if len <= swap_len and right_len >= 64 then
		cross_merge(swap, arr, block_len, right_len)
		mcpy(arr, swap, len)
		return
	end

	mcpy(swap, arr + block_len, right_len)
	local rt = swap + right_len - 1

	while lt > arr + 16 and rt > swap + 16 do
		local stop = false
		while not gt(lt, rt - 15) do
			for _ = 1, 16 do
				m[dt] = m[rt]
				dt = dt - 1
				rt = rt - 1
			end
			if rt <= swap + 16 then stop = true break end
		end
		if stop then break end
		while gt(lt - 15, rt) do
			for _ = 1, 16 do
				m[dt] = m[lt]
				dt = dt - 1
				lt = lt - 1
			end
			if lt <= arr + 16 then stop = true break end
		end
		if stop then break end
		local loops = 8
		while true do
			if not gt(lt, rt - 1) then
				for _ = 1, 2 do
					m[dt] = m[rt]
					dt = dt - 1
					rt = rt - 1
				end
			elseif gt(lt - 1, rt) then
				for _ = 1, 2 do
					m[dt] = m[lt]
					dt = dt - 1
					lt = lt - 1
				end
			else
				local x = gt(lt, rt) and 0 or 1
				dt = dt - 1
				m[dt + x] = m[rt]
				rt = rt - 1
				m[dt + 1 - x] = m[lt]
				lt = lt - 1
				dt = dt - 1
				dt, lt, rt = tail_branchless_merge(dt, lt, rt)
			end
			loops = loops - 1
			if loops == 0 then break end
		end
	end

	while rt > swap + 1 and lt > arr + 1 do
		local done
		dt, lt, rt, done = backward_merge_2(true, dt, arr, lt, swap, rt)
		if done then break end
		local x = gt(lt, rt) and 0 or 1
		dt = dt - 1
		m[dt + x] = m[rt]
		rt = rt - 1
		m[dt + 1 - x] = m[lt]
		lt = lt - 1
		dt = dt - 1
		dt, lt, rt = tail_branchless_merge(dt, lt, rt)
	end

	while rt >= swap and lt >= arr do
		dt, lt, rt = tail_branchless_merge(dt, lt, rt)
	end
	while rt >= swap do
		m[dt] = m[rt]
		dt = dt - 1
		rt = rt - 1
	end
end

-- Merge a full left block with a shorter right chunk, head to tail.
local function partial_forward_merge(arr, len, swap, swap_len, block_len)
	if len == block_len then return end
	local rh = arr + block_len
	local rt = arr + len - 1
	if not gt(rh - 1, rh) then return end

	mcpy(swap, arr, block_len)
	local lh = swap
	local lt = swap + block_len - 1
	local dh = arr

	while lh < lt - 1 and rh < rt - 1 do
		local done
		dh, lh, rh, done = forward_merge_2(true, dh, lh, lt, rh, rt)
		if done then break end
		local x = gt(lh, rh) and 0 or 1
		m[dh + x] = m[rh]
		rh = rh + 1
		m[dh + 1 - x] = m[lh]
		lh = lh + 1
		dh = dh + 2
		dh, lh, rh = head_branchless_merge(dh, lh, rh)
	end

	while lh <= lt and rh <= rt do
		dh, lh, rh = head_branchless_merge(dh, lh, rh)
	end
	while lh <= lt do
		m[dh] = m[lh]
		dh = dh + 1
		lh = lh + 1
	end
end

local function tail_merge(arr, len, swap, swap_len, block_len)
	local end_ptr = arr + len
	local cbl = block_len
	while cbl < len and cbl <= swap_len do
		local p = arr
		while p + cbl < end_ptr do
			if p + 2 * cbl < end_ptr then
				partial_backwards_merge(p, 2 * cbl, swap, swap_len, cbl)
				p = p + 2 * cbl
			else
				partial_backwards_merge(p, end_ptr - p, swap, swap_len, cbl)
				break
			end
		end
		cbl = cbl * 2
	end
end

-- Swap two neighboring chunks with limited memory.
local function trinity_rotation(arr, len, swap, full_swap_len, left_len)
	local right_len = len - left_len
	local swap_len = full_swap_len > 65536 and 65536 or full_swap_len
	local tmp
	if left_len < right_len then
		if left_len <= swap_len then
			mcpy(swap, arr, left_len)
			mcpy(arr, arr + left_len, right_len)
			mcpy(arr + right_len, swap, left_len)
		else
			local a = arr
			local b = a + left_len
			local bridge = right_len - left_len
			if bridge <= swap_len and bridge > 3 then
				local c = a + right_len
				local d = c + left_len
				mcpy(swap, b, bridge)
				for _ = 1, left_len do
					c = c - 1
					d = d - 1
					m[c] = m[d]
					b = b - 1
					m[d] = m[b]
				end
				mcpy(a, swap, bridge)
			else
				local c = b
				local d = c + right_len
				bridge = floor(left_len / 2)
				for _ = 1, bridge do
					b = b - 1
					tmp = m[b]
					m[b] = m[a]
					m[a] = m[c]
					a = a + 1
					d = d - 1
					m[c] = m[d]
					c = c + 1
					m[d] = tmp
				end
				bridge = floor((d - c) / 2)
				for _ = 1, bridge do
					tmp = m[c]
					d = d - 1
					m[c] = m[d]
					c = c + 1
					m[d] = m[a]
					m[a] = tmp
					a = a + 1
				end
				bridge = floor((d - a) / 2)
				for _ = 1, bridge do
					tmp = m[a]
					d = d - 1
					m[a] = m[d]
					a = a + 1
					m[d] = tmp
				end
			end
		end
	elseif right_len < left_len then
		if right_len <= swap_len then
			mcpy(swap, arr + left_len, right_len)
			copy_backwards(arr + right_len, arr, left_len)
			mcpy(arr, swap, right_len)
		else
			local a = arr
			local b = a + left_len
			local bridge = left_len - right_len
			if bridge <= swap_len and bridge > 3 then
				local c = a + right_len
				local d = c + left_len
				mcpy(swap, c, bridge)
				for _ = 1, right_len do
					m[c] = m[a]
					c = c + 1
					m[a] = m[b]
					a = a + 1
					b = b + 1
				end
				mcpy(d - bridge, swap, bridge)
			else
				local c = b
				local d = c + right_len
				bridge = floor(right_len / 2)
				for _ = 1, bridge do
					b = b - 1
					tmp = m[b]
					m[b] = m[a]
					m[a] = m[c]
					a = a + 1
					d = d - 1
					m[c] = m[d]
					c = c + 1
					m[d] = tmp
				end
				bridge = floor((b - a) / 2)
				for _ = 1, bridge do
					b = b - 1
					tmp = m[b]
					m[b] = m[a]
					d = d - 1
					m[a] = m[d]
					a = a + 1
					m[d] = tmp
				end
				bridge = floor((d - a) / 2)
				for _ = 1, bridge do
					tmp = m[a]
					d = d - 1
					m[a] = m[d]
					a = a + 1
					m[d] = tmp
				end
			end
		end
	else
		local l = arr
		local r = l + left_len
		for _ = 1, left_len do
			tmp = m[l]
			m[l] = m[r]
			l = l + 1
			m[r] = tmp
			r = r + 1
		end
	end
end

-- Binary search, but more cache friendly.
local function monobound_binary_first(arr, top, value)
	local end_ptr = arr + top
	while top > 1 do
		local mid = floor(top / 2)
		if not gt(value, end_ptr - mid) then end_ptr = end_ptr - mid end
		top = top - mid
	end
	if not gt(value, end_ptr - 1) then end_ptr = end_ptr - 1 end
	return end_ptr - arr
end

local function rotate_merge_block(arr, swap, swap_len, left_block, right)
	if not gt(arr + left_block - 1, arr + left_block) then return end

	local right_block = floor(left_block / 2)
	left_block = left_block - right_block

	local left = monobound_binary_first(arr + left_block + right_block, right, arr + left_block)
	right = right - left

	if left ~= 0 then
		if left_block + left <= swap_len then
			mcpy(swap, arr, left_block)
			mcpy(swap + left_block, arr + left_block + right_block, left)
			copy_backwards(arr + left + left_block, arr + left_block, right_block)
			cross_merge(arr, swap, left_block, left)
		else
			trinity_rotation(arr + left_block, right_block + left, swap, swap_len, right_block)
			local unbalanced = (left * 2 < left_block) or (left_block * 2 < left)
			if unbalanced and left <= swap_len then
				partial_backwards_merge(arr, left_block + left, swap, swap_len, left_block)
			elseif unbalanced and left_block <= swap_len then
				partial_forward_merge(arr, left_block + left, swap, swap_len, left_block)
			else
				rotate_merge_block(arr, swap, swap_len, left_block, left)
			end
		end
	end

	if right ~= 0 then
		local unbalanced = (right * 2 < right_block) or (right_block * 2 < right)
		local base = arr + left_block + left
		if (unbalanced and right <= swap_len) or right + right_block <= swap_len then
			partial_backwards_merge(base, right_block + right, swap, swap_len, right_block)
		elseif unbalanced and left_block <= swap_len then
			partial_forward_merge(base, right_block + right, swap, swap_len, right_block)
		else
			rotate_merge_block(base, swap, swap_len, right_block, right)
		end
	end
end

local function rotate_merge(arr, len, swap, swap_len, block_len)
	local end_ptr = arr + len
	-- `len -% block_len` wraps in sort.zig, so it only fits when len >= block_len.
	if len <= block_len * 2 and len >= block_len and len - block_len <= swap_len then
		partial_backwards_merge(arr, len, swap, swap_len, block_len)
		return
	end
	local cbl = block_len
	while cbl < len do
		local p = arr
		while p + cbl < end_ptr do
			if p + cbl * 2 < end_ptr then
				rotate_merge_block(p, swap, swap_len, cbl, cbl)
				p = p + cbl * 2
			else
				rotate_merge_block(p, swap, swap_len, cbl, end_ptr - p - cbl)
				break
			end
		end
		cbl = cbl * 2
	end
end

local function quad_merge_block(arr, swap, block_len)
	local bx2 = 2 * block_len
	local b2 = arr + block_len
	local b3 = b2 + block_len
	local b4 = b3 + block_len
	local io12 = not gt(b2 - 1, b2)
	local io34 = not gt(b4 - 1, b4)
	if not io12 and not io34 then
		cross_merge(swap, arr, block_len, block_len)
		cross_merge(swap + bx2, b3, block_len, block_len)
	elseif io12 and not io34 then
		mcpy(swap, arr, bx2)
		cross_merge(swap + bx2, b3, block_len, block_len)
	elseif not io12 and io34 then
		cross_merge(swap, arr, block_len, block_len)
		mcpy(swap + bx2, b3, bx2)
	else
		if not gt(b3 - 1, b3) then return end
		mcpy(swap, arr, bx2 * 2)
	end
	cross_merge(arr, swap, bx2, bx2)
end

local function quad_merge(arr, len, swap, swap_len, block_len)
	local end_ptr = arr + len
	local cbl = block_len * 4
	while cbl <= len and cbl <= swap_len do
		local p = arr
		repeat
			quad_merge_block(p, swap, cbl / 4)
			p = p + cbl
		until p + cbl > end_ptr
		tail_merge(p, end_ptr - p, swap, swap_len, cbl / 4)
		cbl = cbl * 4
	end
	tail_merge(arr, len, swap, swap_len, cbl / 4)
	return cbl / 2
end

-- Small arrays -----------------------------------------------------------------

local function quad_reversal(start, end_)
	local loops = floor((end_ - start) / 2)
	local h1s, h1e = start, start + loops
	local h2s, h2e = end_ - loops, end_
	local tmp
	if loops % 2 == 0 then
		tmp = m[h1e]
		m[h1e] = m[h2s]
		h1e = h1e - 1
		m[h2s] = tmp
		h2s = h2s + 1
		loops = loops - 1
	end
	loops = floor(loops / 2)
	while true do
		tmp = m[h1s]
		m[h1s] = m[h2e]
		h1s = h1s + 1
		m[h2e] = tmp
		h2e = h2e - 1

		tmp = m[h1e]
		m[h1e] = m[h2s]
		h1e = h1e - 1
		m[h2s] = tmp
		h2s = h2s + 1

		if loops == 0 then break end
		loops = loops - 1
	end
end

local function parity_swap_four(arr)
	local p = arr
	swap_branchless(p)
	p = p + 2
	swap_branchless(p)
	p = p - 1
	if gt(p, p + 1) then
		local tmp = m[p]
		m[p] = m[p + 1]
		m[p + 1] = tmp
		p = p - 1
		swap_branchless(p)
		p = p + 2
		swap_branchless(p)
		p = p - 1
		swap_branchless(p)
	end
end

local function parity_swap_five(arr)
	local p = arr
	swap_branchless(p)
	p = p + 2
	swap_branchless(p)
	p = p - 1
	local more = swap_branchless_return_gt(p)
	p = p + 2
	more = more + swap_branchless_return_gt(p)
	p = arr
	if more ~= 0 then
		swap_branchless(p)
		p = p + 2
		swap_branchless(p)
		p = p - 1
		swap_branchless(p)
		p = p + 2
		swap_branchless(p)
		p = arr
		swap_branchless(p)
		p = p + 2
		swap_branchless(p)
	end
end

local function parity_swap_six(arr, swap)
	local p = arr
	swap_branchless(p)
	p = p + 1
	swap_branchless(p)
	p = p + 3
	swap_branchless(p)
	p = p - 1
	swap_branchless(p)
	p = arr
	if not gt(p + 2, p + 3) then
		swap_branchless(p)
		p = p + 4
		swap_branchless(p)
		return
	end
	local x = gt(p, p + 1) and 1 or 0
	m[swap] = m[p + x]
	m[swap + 1] = m[p + 1 - x]
	m[swap + 2] = m[p + 2]
	p = p + 4
	x = gt(p, p + 1) and 1 or 0
	m[swap + 4] = m[p + x]
	m[swap + 5] = m[p + 1 - x]
	m[swap + 3] = m[p - 1]

	local lrem, rrem = 3, 3
	local d, l, r, tl = arr, swap, swap + 3, nil
	for _ = 1, 3 do
		d, l, r, tl = head_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
	d, l, r = arr + 5, swap + 2, swap + 5
	for _ = 1, 3 do
		d, l, r, tl = tail_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
end

local function parity_swap_seven(arr, swap)
	local p = arr
	swap_branchless(p)
	p = p + 2
	swap_branchless(p)
	p = p + 2
	swap_branchless(p)
	p = p - 3
	local more = swap_branchless_return_gt(p)
	p = p + 2
	more = more + swap_branchless_return_gt(p)
	p = p + 2
	more = more + swap_branchless_return_gt(p)
	p = p - 1
	if more == 0 then return end
	swap_branchless(p)
	p = arr

	local x = gt(p, p + 1) and 1 or 0
	m[swap] = m[p + x]
	m[swap + 1] = m[p + 1 - x]
	m[swap + 2] = m[p + 2]
	p = p + 3
	x = gt(p, p + 1) and 1 or 0
	m[swap + 3] = m[p + x]
	m[swap + 4] = m[p + 1 - x]
	p = p + 2
	x = gt(p, p + 1) and 1 or 0
	m[swap + 5] = m[p + x]
	m[swap + 6] = m[p + 1 - x]

	local lrem, rrem = 3, 4
	local d, l, r, tl = arr, swap, swap + 3, nil
	for _ = 1, 3 do
		d, l, r, tl = head_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
	d, l, r = arr + 6, swap + 2, swap + 6
	for _ = 1, 4 do
		d, l, r, tl = tail_guarded_merge(d, l, r, lrem ~= 0, rrem ~= 0)
		if tl then lrem = lrem - 1 else rrem = rrem - 1 end
	end
end

local function tiny_sort(arr, len, swap)
	if len <= 1 then return end
	if len == 2 then
		swap_branchless(arr)
	elseif len == 3 then
		swap_branchless(arr)
		swap_branchless(arr + 1)
		swap_branchless(arr)
	elseif len == 4 then
		parity_swap_four(arr)
	elseif len == 5 then
		parity_swap_five(arr)
	elseif len == 6 then
		parity_swap_six(arr, swap)
	else
		parity_swap_seven(arr, swap)
	end
end

local function tail_swap(arr, len, swap)
	if len < 8 then
		tiny_sort(arr, len, swap)
		return
	end
	local half1 = floor(len / 2)
	local quad1 = floor(half1 / 2)
	local quad2 = half1 - quad1
	local half2 = len - half1
	local quad3 = floor(half2 / 2)
	local quad4 = half2 - quad3

	local p = arr
	tail_swap(p, quad1, swap)
	p = p + quad1
	tail_swap(p, quad2, swap)
	p = p + quad2
	tail_swap(p, quad3, swap)
	p = p + quad3
	tail_swap(p, quad4, swap)

	if not gt(arr + quad1 - 1, arr + quad1) and not gt(arr + half1 - 1, arr + half1) and not gt(p - 1, p) then
		return
	end
	parity_merge(swap, arr, quad1, quad2)
	parity_merge(swap + half1, arr + half1, quad3, quad4)
	parity_merge(arr, swap, half1, half2)
end

local function quad_swap_merge(arr, swap)
	parity_merge_two(swap, arr)
	parity_merge_two(swap + 4, arr + 4)
	parity_merge_four(arr, swap)
end

-- Swap the pairs of an 8-element block whose flag says "greater".
local function swap_pairs(p, g1, g2, g3, g4)
	local tmp
	if g1 then tmp = m[p]; m[p] = m[p + 1]; m[p + 1] = tmp end
	if g2 then tmp = m[p + 2]; m[p + 2] = m[p + 3]; m[p + 3] = tmp end
	if g3 then tmp = m[p + 4]; m[p + 4] = m[p + 5]; m[p + 5] = tmp end
	if g4 then tmp = m[p + 6]; m[p + 6] = m[p + 7]; m[p + 7] = tmp end
end

local NOT_ORDERED, ORDERED, REVERSED = 0, 1, 2

-- Turn an unsorted array into sorted blocks of 32; true when it fully sorted it.
local function quad_swap(arr, len)
	local saved = stk
	local swap = alloc(32)
	local p = arr
	local reverse_head = p
	local count = floor(len / 8)
	local skip_tail_swap = false
	local v1, v2, v3, v4, state

	while count ~= 0 do
		count = count - 1
		v1 = gt(p, p + 1) and 1 or 0
		v2 = gt(p + 2, p + 3) and 1 or 0
		v3 = gt(p + 4, p + 5) and 1 or 0
		v4 = gt(p + 6, p + 7) and 1 or 0
		local sw = v1 + v2 * 2 + v3 * 4 + v4 * 8
		local next_block = false
		if sw == 0 then
			if not gt(p + 1, p + 2) and not gt(p + 3, p + 4) and not gt(p + 5, p + 6) then
				state = ORDERED
			else
				quad_swap_merge(p, swap)
				p = p + 8
				next_block = true
			end
		elseif sw == 15 then
			if gt(p + 1, p + 2) and gt(p + 3, p + 4) and gt(p + 5, p + 6) then
				reverse_head = p
				state = REVERSED
			else
				state = NOT_ORDERED
			end
		else
			state = NOT_ORDERED
		end

		local finished = false -- `break :outer`
		while not next_block do
			if state == NOT_ORDERED then
				swap_pairs(p, v1 ~= 0, v2 ~= 0, v3 ~= 0, v4 ~= 0)
				quad_swap_merge(p, swap)
				p = p + 8
				next_block = true
			elseif state == ORDERED then
				p = p + 8
				if count ~= 0 then
					count = count - 1
					v1 = gt(p, p + 1) and 1 or 0
					v2 = gt(p + 2, p + 3) and 1 or 0
					v3 = gt(p + 4, p + 5) and 1 or 0
					v4 = gt(p + 6, p + 7) and 1 or 0
					if v1 + v2 + v3 + v4 ~= 0 then
						if v1 + v2 + v3 + v4 == 4 and gt(p + 1, p + 2) and gt(p + 3, p + 4) and gt(p + 5, p + 6) then
							reverse_head = p
							state = REVERSED
						else
							state = NOT_ORDERED
						end
					elseif not gt(p + 1, p + 2) and not gt(p + 3, p + 4) and not gt(p + 5, p + 6) then
						state = ORDERED
					else
						quad_swap_merge(p, swap)
						p = p + 8
						next_block = true
					end
				else
					finished = true
					break
				end
			else -- REVERSED
				p = p + 8
				if count ~= 0 then
					count = count - 1
					v1 = gt(p, p + 1) and 0 or 1
					v2 = gt(p + 2, p + 3) and 0 or 1
					v3 = gt(p + 4, p + 5) and 0 or 1
					v4 = gt(p + 6, p + 7) and 0 or 1
					local still_reversed = false
					if v1 + v2 + v3 + v4 == 0 then
						if gt(p - 1, p) and gt(p + 1, p + 2) and gt(p + 3, p + 4) and gt(p + 5, p + 6) then
							still_reversed = true
						end
					end
					if not still_reversed then
						quad_reversal(reverse_head, p - 1)
						if v1 + v2 + v3 + v4 == 4 and not gt(p + 1, p + 2) and not gt(p + 3, p + 4) and not gt(p + 5, p + 6) then
							state = ORDERED
						elseif v1 + v2 + v3 + v4 == 0 and gt(p + 1, p + 2) and gt(p + 3, p + 4) and gt(p + 5, p + 6) then
							reverse_head = p
							state = REVERSED
						else
							swap_pairs(p, v1 == 0, v2 == 0, v3 == 0, v4 == 0)
							if gt(p + 1, p + 2) or gt(p + 3, p + 4) or gt(p + 5, p + 6) then
								quad_swap_merge(p, swap)
							end
							p = p + 8
							next_block = true
						end
					end
				else
					local rem = len % 8
					local ok = true
					if ok and rem == 7 and not gt(p + 5, p + 6) then ok = false end
					if ok and rem >= 6 and not gt(p + 4, p + 5) then ok = false end
					if ok and rem >= 5 and not gt(p + 3, p + 4) then ok = false end
					if ok and rem >= 4 and not gt(p + 2, p + 3) then ok = false end
					if ok and rem >= 3 and not gt(p + 1, p + 2) then ok = false end
					if ok and rem >= 2 and not gt(p, p + 1) then ok = false end
					if ok and rem >= 1 and not gt(p - 1, p) then ok = false end
					if ok then
						quad_reversal(reverse_head, p + rem - 1)
						if reverse_head == arr then
							stk = saved
							return true
						end
						skip_tail_swap = true
					else
						quad_reversal(reverse_head, p - 1)
					end
					finished = true
					break
				end
			end
		end
		if finished then break end
	end

	if not skip_tail_swap then tail_swap(p, len % 8, swap) end

	p = arr
	count = floor(len / 32)
	while count ~= 0 do
		if not (not gt(p + 7, p + 8) and not gt(p + 15, p + 16) and not gt(p + 23, p + 24)) then
			parity_merge(swap, p, 8, 8)
			parity_merge(swap + 16, p + 16, 8, 8)
			parity_merge(p, swap, 16, 16)
		end
		count = count - 1
		p = p + 32
	end

	if len % 32 > 8 then tail_merge(p, len % 32, swap, 32, 8) end

	stk = saved
	return false
end

-- Quadsort with caller-provided swap space.
local function quadsort_swap(arr, len, swap, swap_len)
	if len < 96 then
		tail_swap(arr, len, swap)
	elseif not quad_swap(arr, len) then
		local block_len = quad_merge(arr, len, swap, swap_len, 32)
		rotate_merge(arr, len, swap, swap_len, block_len)
	end
end

local function quadsort_direct(arr, len)
	local saved = stk
	if len < 32 then
		tail_swap(arr, len, alloc(32))
	elseif not quad_swap(arr, len) then
		local swap = alloc(len)
		local block_len = quad_merge(arr, len, swap, len, 32)
		rotate_merge(arr, len, swap, len, block_len)
	end
	stk = saved
end

-- Pivot selection --------------------------------------------------------------

local function binary_median(a, b, len, out)
	len = floor(len / 2)
	while len ~= 0 do
		if not gt(a, b) then a = a + len else b = b + len end
		len = floor(len / 2)
	end
	m[out] = m[gt(a, b) and a or b]
end

local function trim_four(a)
	local x = gt(a, a + 1) and 1 or 0
	local tmp = m[a + 1 - x]
	m[a] = m[a + x]
	m[a + 1] = tmp
	a = a + 2
	x = gt(a, a + 1) and 1 or 0
	tmp = m[a + 1 - x]
	m[a] = m[a + x]
	m[a + 1] = tmp
	a = a - 2
	x = gt(a, a + 2) and 0 or 2
	m[a + 2] = m[a + x]
	a = a + 1
	x = gt(a, a + 2) and 2 or 0
	m[a] = m[a + x]
end

local function median_of_nine(arr, len, out)
	local saved = stk
	local s = alloc(9)
	local p = arr
	local offset = floor(len / 9)
	for x = 0, 8 do
		m[s + x] = m[p]
		p = p + offset
	end
	trim_four(s)
	trim_four(s + 4)
	m[s] = m[s + 5]
	m[s + 3] = m[s + 8]
	trim_four(s)
	m[s] = m[s + 6]
	local x = gt(s, s + 1) and 1 or 0
	local y = gt(s, s + 2) and 1 or 0
	local z = gt(s + 1, s + 2) and 1 or 0
	local index = (x == y and 1 or 0) + bxor(x, z)
	m[out] = m[s + index]
	stk = saved
end

-- Returns whether the sampled elements were all equal ("generic").
local function median_of_cube_root(array, swap, x, len, out)
	local cbrt = 32
	while len > cbrt * cbrt * cbrt do cbrt = cbrt * 2 end
	local div = floor(len / cbrt)
	local p = x -- sort.zig: x + (stack address / 16 % div); see the header.
	local sp = (x == array) and swap or array
	for cnt = 0, cbrt - 1 do
		m[sp + cnt] = m[p]
		p = p + div
	end
	cbrt = cbrt / 2
	quadsort_swap(sp, cbrt, sp + cbrt * 2, cbrt)
	quadsort_swap(sp + cbrt, cbrt, sp + cbrt * 2, cbrt)
	local generic = not gt(sp + cbrt * 2 - 1, sp) and not gt(sp + cbrt - 1, sp)
	binary_median(sp, sp + cbrt, cbrt, out)
	return generic
end

-- Fluxsort partitions ----------------------------------------------------------

local flux_partition

local function flux_reverse_partition(array, swap, x, pivot, len)
	local ap, sp = array, swap
	for _ = 1, len do
		if gt(pivot, x) then
			m[ap] = m[x]
			ap = ap + 1
		else
			m[sp] = m[x]
			sp = sp + 1
		end
		x = x + 1
	end
	local arr_len = ap - array
	local swap_len = sp - swap
	mcpy(array + arr_len, swap, swap_len)
	if swap_len <= floor(arr_len / 16) or arr_len <= FLUX_OUT then
		quadsort_swap(array, arr_len, swap, arr_len)
		return
	end
	flux_partition(array, swap, array, pivot, arr_len)
end

-- Partition x around pivot (elements <= pivot into array); returns the count
-- left in array, or 0 when it finished sorting with quadsort.
local function flux_default_partition(array, swap, x, pivot, len)
	local ap, sp = array, swap
	local run = 0
	local a = 8
	while a <= len do
		for _ = 1, 8 do
			if not gt(x, pivot) then
				m[ap] = m[x]
				ap = ap + 1
			else
				m[sp] = m[x]
				sp = sp + 1
			end
			x = x + 1
		end
		if ap == array or sp == swap then run = a end
		a = a + 8
	end
	for _ = 1, len % 8 do
		if not gt(x, pivot) then
			m[ap] = m[x]
			ap = ap + 1
		else
			m[sp] = m[x]
			sp = sp + 1
		end
		x = x + 1
	end
	local mm = ap - array
	if run <= floor(len / 4) then return mm end
	if mm == len then return mm end
	a = len - mm
	mcpy(array + mm, swap, a)
	quadsort_swap(array + mm, a, swap, a)
	quadsort_swap(array, mm, swap, mm)
	return 0
end

flux_partition = function(array, swap, x, pivot, len)
	local pp = pivot
	local xp = x
	local arr_len = 0
	local swap_len
	while true do
		pp = pp - 1
		if len <= 2048 then
			median_of_nine(xp, len, pp)
		elseif median_of_cube_root(array, swap, xp, len, pp) then
			if xp == swap then mcpy(array, swap, len) end
			quadsort_swap(array, len, swap, len)
			return
		end

		if arr_len ~= 0 and not gt(pp + 1, pp) then
			flux_reverse_partition(array, swap, array, pp, len)
			return
		end
		arr_len = flux_default_partition(array, swap, xp, pp, len)
		swap_len = len - arr_len

		if arr_len <= floor(swap_len / 32) or swap_len <= FLUX_OUT then
			if arr_len == 0 then return end
			if swap_len == 0 then
				flux_reverse_partition(array, swap, array, pp, arr_len)
				return
			end
			mcpy(array + arr_len, swap, swap_len)
			quadsort_swap(array + arr_len, swap_len, swap, swap_len)
		else
			flux_partition(array + arr_len, swap, swap, pp, swap_len)
		end

		if swap_len <= floor(arr_len / 32) or arr_len <= FLUX_OUT then
			if arr_len <= FLUX_OUT then
				quadsort_swap(array, arr_len, swap, arr_len)
			else
				flux_reverse_partition(array, swap, array, pp, arr_len)
			end
			return
		end
		len = arr_len
		xp = array
	end
end

-- Choose mergesort or quicksort per quarter from sampled orderedness.
local function flux_analyze(array, len, swap, swap_len)
	local half1 = floor(len / 2)
	local quad1 = floor(half1 / 2)
	local quad2 = half1 - quad1
	local half2 = len - half1
	local quad3 = floor(half2 / 2)
	local quad4 = half2 - quad3

	local pa = array
	local pb = array + quad1
	local pc = array + half1
	local pd = array + half1 + quad3

	local sa, sb, sc, sd = 0, 0, 0, 0
	local ba, bb, bc, bd = 0, 0, 0, 0

	if quad1 < quad2 then
		if gt(pb, pb + 1) then bb = bb + 1 end
		pb = pb + 1
	end
	if quad1 < quad3 then
		if gt(pc, pc + 1) then bc = bc + 1 end
		pc = pc + 1
	end
	if quad1 < quad4 then
		if gt(pd, pd + 1) then bd = bd + 1 end
		pd = pd + 1
	end

	local count = len
	while count > 132 do
		local suma, sumb, sumc, sumd = 0, 0, 0, 0
		for _ = 1, 32 do
			if gt(pa, pa + 1) then suma = suma + 1 end
			pa = pa + 1
			if gt(pb, pb + 1) then sumb = sumb + 1 end
			pb = pb + 1
			if gt(pc, pc + 1) then sumc = sumc + 1 end
			pc = pc + 1
			if gt(pd, pd + 1) then sumd = sumd + 1 end
			pd = pd + 1
		end
		ba = ba + suma
		suma = (suma == 0 or suma == 32) and 1 or 0
		sa = sa + suma
		bb = bb + sumb
		sumb = (sumb == 0 or sumb == 32) and 1 or 0
		sb = sb + sumb
		bc = bc + sumc
		sumc = (sumc == 0 or sumc == 32) and 1 or 0
		sc = sc + sumc
		bd = bd + sumd
		sumd = (sumd == 0 or sumd == 32) and 1 or 0
		sd = sd + sumd

		if count > 516 and suma + sumb + sumc + sumd == 0 then
			ba = ba + 48
			pa = pa + 96
			bb = bb + 48
			pb = pb + 96
			bc = bc + 48
			pc = pc + 96
			bd = bd + 48
			pd = pd + 96
			count = count - 384
		end
		count = count - 128
	end

	while count > 7 do
		if gt(pa, pa + 1) then ba = ba + 1 end
		pa = pa + 1
		if gt(pb, pb + 1) then bb = bb + 1 end
		pb = pb + 1
		if gt(pc, pc + 1) then bc = bc + 1 end
		pc = pc + 1
		if gt(pd, pd + 1) then bd = bd + 1 end
		pd = pd + 1
		count = count - 4
	end

	count = ba + bb + bc + bd
	if count == 0 then
		if not gt(pa, pa + 1) and not gt(pb, pb + 1) and not gt(pc, pc + 1) then return end
	end

	local ra = quad1 - ba == 1
	local rb = quad2 - bb == 1
	local rc = quad3 - bc == 1
	local rd = quad4 - bd == 1

	if ra or rb or rc or rd then
		-- All three comparisons happen (a product in sort.zig, not a short circuit).
		local g1 = gt(pa, pa + 1)
		local g2 = gt(pb, pb + 1)
		local g3 = gt(pc, pc + 1)
		local span = ((ra and rb and g1) and 1 or 0) + ((rb and rc and g2) and 2 or 0) + ((rc and rd and g3) and 4 or 0)
		if span == 1 then
			quad_reversal(array, pb)
			ba, bb = 0, 0
		elseif span == 2 then
			quad_reversal(pa + 1, pc)
			bb, bc = 0, 0
		elseif span == 3 then
			quad_reversal(array, pc)
			ba, bb, bc = 0, 0, 0
		elseif span == 4 then
			quad_reversal(pb + 1, pd)
			bc, bd = 0, 0
		elseif span == 5 then
			quad_reversal(array, pb)
			ba, bb = 0, 0
			quad_reversal(pb + 1, pd)
			bc, bd = 0, 0
		elseif span == 6 then
			quad_reversal(pa + 1, pd)
			bb, bc, bd = 0, 0, 0
		elseif span == 7 then
			quad_reversal(array, pd)
			return
		end
		if ra and ba ~= 0 then
			quad_reversal(array, pa)
			ba = 0
		end
		if rb and bb ~= 0 then
			quad_reversal(pa + 1, pb)
			bb = 0
		end
		if rc and bc ~= 0 then
			quad_reversal(pb + 1, pc)
			bc = 0
		end
		if rd and bd ~= 0 then
			quad_reversal(pc + 1, pd)
			bd = 0
		end
	end

	count = floor(len / 512)
	local oa = sa > count and 1 or 0
	local ob = sb > count and 1 or 0
	local oc = sc > count and 1 or 0
	local od = sd > count and 1 or 0
	if quad1 > QUAD_CACHE then oa, ob, oc, od = 1, 1, 1, 1 end

	local sw = oa + ob * 2 + oc * 4 + od * 8
	if sw == 0 then
		flux_partition(array, swap, array, swap + len, len)
		return
	elseif sw == 1 then
		if ba ~= 0 then quadsort_swap(array, quad1, swap, swap_len) end
		flux_partition(pa + 1, swap, pa + 1, swap + quad2 + half2, quad2 + half2)
	elseif sw == 2 then
		flux_partition(array, swap, array, swap + quad1, quad1)
		if bb ~= 0 then quadsort_swap(pa + 1, quad2, swap, swap_len) end
		flux_partition(pb + 1, swap, pb + 1, swap + half2, half2)
	elseif sw == 3 then
		if ba ~= 0 then quadsort_swap(array, quad1, swap, swap_len) end
		if bb ~= 0 then quadsort_swap(pa + 1, quad2, swap, swap_len) end
		flux_partition(pb + 1, swap, pb + 1, swap + half2, half2)
	elseif sw == 4 then
		flux_partition(array, swap, array, swap + half1, half1)
		if bc ~= 0 then quadsort_swap(pb + 1, quad3, swap, swap_len) end
		flux_partition(pc + 1, swap, pc + 1, swap + quad4, quad4)
	elseif sw == 8 then
		flux_partition(array, swap, array, swap + half1 + quad3, half1 + quad3)
		if bd ~= 0 then quadsort_swap(pc + 1, quad4, swap, swap_len) end
	elseif sw == 9 then
		if ba ~= 0 then quadsort_swap(array, quad1, swap, swap_len) end
		flux_partition(pa + 1, swap, pa + 1, swap + quad2 + quad3, quad2 + quad3)
		if bd ~= 0 then quadsort_swap(pc + 1, quad4, swap, swap_len) end
	elseif sw == 12 then
		flux_partition(array, swap, array, swap + half1, half1)
		if bc ~= 0 then quadsort_swap(pb + 1, quad3, swap, swap_len) end
		if bd ~= 0 then quadsort_swap(pc + 1, quad4, swap, swap_len) end
	else
		if oa ~= 0 then
			if ba ~= 0 then quadsort_swap(array, quad1, swap, swap_len) end
		else
			flux_partition(array, swap, array, swap + quad1, quad1)
		end
		if ob ~= 0 then
			if bb ~= 0 then quadsort_swap(pa + 1, quad2, swap, swap_len) end
		else
			flux_partition(pa + 1, swap, pa + 1, swap + quad2, quad2)
		end
		if oc ~= 0 then
			if bc ~= 0 then quadsort_swap(pb + 1, quad3, swap, swap_len) end
		else
			flux_partition(pb + 1, swap, pb + 1, swap + quad3, quad3)
		end
		if od ~= 0 then
			if bd ~= 0 then quadsort_swap(pc + 1, quad4, swap, swap_len) end
		else
			flux_partition(pc + 1, swap, pc + 1, swap + quad4, quad4)
		end
	end

	if not gt(pa, pa + 1) then
		if not gt(pc, pc + 1) then
			if not gt(pb, pb + 1) then return end
			mcpy(swap, array, len)
		else
			cross_merge(swap + half1, array + half1, quad3, quad4)
			mcpy(swap, array, half1)
		end
	else
		if not gt(pc, pc + 1) then
			mcpy(swap + half1, array + half1, half2)
			cross_merge(swap, array, quad1, quad2)
		else
			cross_merge(swap + half1, pb + 1, quad3, quad4)
			cross_merge(swap, array, quad1, quad2)
		end
	end
	cross_merge(array, swap, half1, half2)
end

-- Sort mem[1..len] in place. `is_after(a, b)` is true when the comparator
-- orders a After b. Slots above len are scratch; `mem` is the caller's temporary.
local function fluxsort(mem, len, is_after)
	local sm, sa, ss = m, after, stk
	m, after, stk = mem, is_after, len + 1
	if len < 132 then
		quadsort_direct(1, len)
	else
		flux_analyze(1, len, alloc(len), len)
	end
	m, after, stk = sm, sa, ss
end

return { fluxsort = fluxsort }
