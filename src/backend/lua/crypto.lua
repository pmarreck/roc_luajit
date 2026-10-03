-- SHA-256 and BLAKE3 for the roc_luajit runtime: ports of src/builtins/crypto.zig,
-- its sha256.zig hasher and Zig std's Blake3, including their incremental
-- buffering. Programs hold the serialized hasher states as List(U8), so the
-- state formats (crypto.zig's own, documented there) and every buffering
-- decision that shows in them follow the builtins exactly.
--
-- Words are Lua numbers kept as signed 32-bit values by `bit`; additions are
-- exact in a double before `tobit` reduces them modulo 2^32.
return function(L, crash)
	local bit = require("bit")
	local band, bor, bxor, bnot, ror, tobit = bit.band, bit.bor, bit.bxor, bit.bnot, bit.ror, bit.tobit
	local rshift, lshift = bit.rshift, bit.lshift
	local floor = math.floor
	local M = {}

	local DIGEST = 32

	local function invariant(message) crash("crypto builtin invariant violated: " .. message) end

	-- List(U8) <-> 1-based byte arrays.
	local function list_bytes(l)
		local out = {}
		for i = 0, l[3] - 1 do out[i + 1] = L.get_unsafe(l, i) end
		return out
	end
	-- RocList.fromSlice: list_allocate's capacity, or the empty list.
	local function bytes_list(b, n)
		if n == 0 then return (L.empty()) end
		local l = L.allocate(n, 1)
		for i = 1, n do l[1][i] = b[i] end
		return l
	end

	local function u32(w) return w % 4294967296 end
	local function put_le32(b, at, w)
		w = u32(w)
		for k = 0, 3 do
			b[at + k] = w % 256
			w = floor(w / 256)
		end
	end
	local function get_le32(b, at) return (tobit(b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216)) end
	local function put_le64(b, at, v)
		for k = 0, 7 do
			b[at + k] = v % 256
			v = floor(v / 256)
		end
	end
	local function get_le64(b, at)
		local v = 0
		for k = 7, 0, -1 do v = v * 256 + b[at + k] end
		return v
	end

	-- SHA-256 (sha256.zig) ------------------------------------------------------

	local K = {
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	}
	for i = 1, 64 do K[i] = tobit(K[i]) end
	local SHA_IV = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	for i = 1, 8 do SHA_IV[i] = tobit(SHA_IV[i]) end

	-- Compress the 64-byte block at b[at..at+63] into state h (8 words).
	local w = {}
	local function sha_compress(h, b, at)
		for t = 0, 15 do
			local p = at + 4 * t
			w[t] = tobit(b[p] * 16777216 + b[p + 1] * 65536 + b[p + 2] * 256 + b[p + 3])
		end
		for t = 16, 63 do
			local x, y = w[t - 15], w[t - 2]
			local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
			local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
			w[t] = tobit(w[t - 16] + s0 + w[t - 7] + s1)
		end
		local a, b2, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
		for t = 0, 63 do
			local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = tobit(hh + S1 + ch + K[t + 1] + w[t])
			local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
			local maj = bxor(band(a, b2), band(a, c), band(b2, c))
			local t2 = tobit(S0 + maj)
			hh, g, f, e = g, f, e, tobit(d + t1)
			d, c, b2, a = c, b2, a, tobit(t1 + t2)
		end
		h[1], h[2], h[3], h[4] = tobit(h[1] + a), tobit(h[2] + b2), tobit(h[3] + c), tobit(h[4] + d)
		h[5], h[6], h[7], h[8] = tobit(h[5] + e), tobit(h[6] + f), tobit(h[7] + g), tobit(h[8] + hh)
	end

	local function sha_init()
		local s = { h = {}, buf = {}, buf_len = 0, total = 0 }
		for i = 1, 8 do s.h[i] = SHA_IV[i] end
		for i = 1, 64 do s.buf[i] = 0 end
		return s
	end

	-- Hasher.update: complete a partial block, compress whole blocks straight
	-- from the input, buffer the rest (the buffer never holds a whole block).
	local function sha_update(s, b, n)
		local off = 0
		if s.buf_len ~= 0 and s.buf_len + n >= 64 then
			off = 64 - s.buf_len
			for i = 1, off do s.buf[s.buf_len + i] = b[i] end
			sha_compress(s.h, s.buf, 1)
			s.buf_len = 0
		end
		local full = floor((n - off) / 64)
		for k = 0, full - 1 do sha_compress(s.h, b, off + 64 * k + 1) end
		off = off + 64 * full
		for i = 1, n - off do s.buf[s.buf_len + i] = b[off + i] end
		s.buf_len = s.buf_len + (n - off)
		s.total = s.total + n
	end

	local function sha_final(s)
		local buf = {}
		for i = 1, 64 do buf[i] = i <= s.buf_len and s.buf[i] or 0 end
		buf[s.buf_len + 1] = 0x80
		local h = { s.h[1], s.h[2], s.h[3], s.h[4], s.h[5], s.h[6], s.h[7], s.h[8] }
		if 64 - (s.buf_len + 1) < 8 then
			sha_compress(h, buf, 1)
			for i = 1, 64 do buf[i] = 0 end
		end
		local bits = s.total * 8
		for k = 64, 57, -1 do
			buf[k] = bits % 256
			bits = floor(bits / 256)
		end
		sha_compress(h, buf, 1)
		local out = {}
		for i = 1, 8 do
			local x = u32(h[i])
			for k = 3, 0, -1 do
				out[4 * (i - 1) + k + 1] = x % 256
				x = floor(x / 256)
			end
		end
		return out
	end

	local SHA_STATE_LEN = 1 + 32 + 64 + 1 + 8

	local function sha_serialize(s)
		local b = { 1 }
		for i = 1, 8 do put_le32(b, 2 + 4 * (i - 1), s.h[i]) end
		for i = 1, 64 do b[33 + i] = i <= s.buf_len and s.buf[i] or 0 end
		b[98] = s.buf_len
		put_le64(b, 99, s.total)
		return (bytes_list(b, SHA_STATE_LEN))
	end

	local function sha_deserialize(l)
		if l[3] ~= SHA_STATE_LEN then invariant("bad SHA256 state length") end
		local b = list_bytes(l)
		if b[1] ~= 1 then invariant("bad SHA256 state version") end
		local s = sha_init()
		for i = 1, 8 do s.h[i] = get_le32(b, 2 + 4 * (i - 1)) end
		for i = 1, 64 do s.buf[i] = b[33 + i] end
		s.buf_len = b[98]
		if s.buf_len > 64 then invariant("bad SHA256 buffer length") end
		s.total = get_le64(b, 99)
		if s.total % 64 ~= s.buf_len then invariant("bad SHA256 total length") end
		return s
	end

	function M.sha256_hash_bytes(l)
		local s = sha_init()
		sha_update(s, list_bytes(l), l[3])
		return (bytes_list(sha_final(s), DIGEST))
	end
	function M.sha256_hasher_empty() return (sha_serialize(sha_init())) end
	function M.sha256_hasher_write(state, l)
		local s = sha_deserialize(state)
		sha_update(s, list_bytes(l), l[3])
		return (sha_serialize(s))
	end
	function M.sha256_hasher_finish(state) return (bytes_list(sha_final(sha_deserialize(state)), DIGEST)) end

	-- BLAKE3 (std.crypto.hash.Blake3) --------------------------------------------

	local CHUNK = 1024
	local B3_IV = { 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 }
	for i = 1, 8 do B3_IV[i] = tobit(B3_IV[i]) end
	local CHUNK_START, CHUNK_END, PARENT, ROOT = 1, 2, 4, 8
	local SCHEDULE = {
		{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
		{ 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 },
		{ 3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1 },
		{ 10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6 },
		{ 12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4 },
		{ 9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7 },
		{ 11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13 },
	}

	local st, mw = {}, {}
	local function g(a, b, c, d, x, y)
		st[a] = tobit(st[a] + st[b] + x)
		st[d] = ror(bxor(st[d], st[a]), 16)
		st[c] = tobit(st[c] + st[d])
		st[b] = ror(bxor(st[b], st[c]), 12)
		st[a] = tobit(st[a] + st[b] + y)
		st[d] = ror(bxor(st[d], st[a]), 8)
		st[c] = tobit(st[c] + st[d])
		st[b] = ror(bxor(st[b], st[c]), 7)
	end
	-- compressPre over the 64-byte block at b[at..]; leaves the state in `st`.
	local function compress_pre(cv, b, at, block_len, counter, flags)
		for i = 0, 15 do mw[i] = get_le32(b, at + 4 * i) end
		for i = 0, 7 do st[i] = cv[i + 1] end
		for i = 0, 3 do st[i + 8] = B3_IV[i + 1] end
		st[12] = tobit(counter % 4294967296)
		st[13] = tobit(floor(counter / 4294967296))
		st[14] = block_len
		st[15] = flags
		for r = 1, 7 do
			local s = SCHEDULE[r]
			g(0, 4, 8, 12, mw[s[1]], mw[s[2]])
			g(1, 5, 9, 13, mw[s[3]], mw[s[4]])
			g(2, 6, 10, 14, mw[s[5]], mw[s[6]])
			g(3, 7, 11, 15, mw[s[7]], mw[s[8]])
			g(0, 5, 10, 15, mw[s[9]], mw[s[10]])
			g(1, 6, 11, 12, mw[s[11]], mw[s[12]])
			g(2, 7, 8, 13, mw[s[13]], mw[s[14]])
			g(3, 4, 9, 14, mw[s[15]], mw[s[16]])
		end
	end
	local function compress_cv(cv, b, at, block_len, counter, flags)
		compress_pre(cv, b, at, block_len, counter, flags)
		local out = {}
		for i = 0, 7 do out[i + 1] = bxor(st[i], st[i + 8]) end
		return out
	end

	local function zero_block()
		local b = {}
		for i = 1, 64 do b[i] = 0 end
		return b
	end

	-- ChunkState: the 64-byte buffer is compressed only once more input
	-- arrives, so a full final block stays buffered.
	local function chunk_init(key, flags, counter)
		return { cv = { unpack(key) }, counter = counter, buf = zero_block(), buf_len = 0, blocks = 0, flags = flags }
	end
	local function chunk_len(c) return 64 * c.blocks + c.buf_len end
	local function start_flag(c) return c.blocks == 0 and CHUNK_START or 0 end
	local function chunk_update(c, b, at, n)
		local pos, stop = at, at + n
		while pos < stop do
			if c.buf_len == 64 then
				c.cv = compress_cv(c.cv, c.buf, 1, 64, c.counter, bor(c.flags, start_flag(c)))
				c.blocks = c.blocks + 1
				c.buf = zero_block()
				c.buf_len = 0
			end
			local take = math.min(64 - c.buf_len, stop - pos)
			for i = 0, take - 1 do c.buf[c.buf_len + i + 1] = b[pos + i] end
			c.buf_len = c.buf_len + take
			pos = pos + take
		end
	end
	-- An Output: input cv, block, block length, counter, flags.
	local function chunk_output(c)
		return { cv = c.cv, block = c.buf, len = c.buf_len, counter = c.counter, flags = bor(c.flags, start_flag(c), CHUNK_END) }
	end
	local function chaining_value(o) return (compress_cv(o.cv, o.block, 1, o.len, o.counter, o.flags)) end
	local function parent_output(left, right, key, flags)
		local block = {}
		for i = 1, 8 do
			put_le32(block, 4 * (i - 1) + 1, left[i])
			put_le32(block, 4 * (i - 1) + 33, right[i])
		end
		return { cv = key, block = block, len = 64, counter = 0, flags = bor(flags, PARENT) }
	end

	local function popcount(x)
		local c = 0
		while x > 0 do
			c = c + x % 2
			x = floor(x / 2)
		end
		return c
	end
	local function merge_cv_stack(h, total)
		local post = popcount(total)
		while #h.stack > post do
			local right = table.remove(h.stack)
			local left = h.stack[#h.stack]
			h.stack[#h.stack] = chaining_value(parent_output(left, right, h.key, h.chunk.flags))
		end
	end
	local function push_cv(h, cv, counter)
		merge_cv_stack(h, counter)
		h.stack[#h.stack + 1] = cv
	end

	-- Chaining value of a power-of-two run of whole chunks: the root of its
	-- canonical subtree (what compressSubtreeWide reduces to, whatever its
	-- SIMD degree), as a non-root node.
	local function subtree_cv(h, b, at, len, counter)
		if len == CHUNK then
			local c = chunk_init(h.key, h.chunk.flags, counter)
			chunk_update(c, b, at, len)
			return (chaining_value(chunk_output(c)))
		end
		local half = len / 2
		local left = subtree_cv(h, b, at, half, counter)
		local right = subtree_cv(h, b, at + half, half, counter + half / CHUNK)
		return (chaining_value(parent_output(left, right, h.key, h.chunk.flags)))
	end

	local function round_down_pow2(x)
		local p = 1
		while p * 2 <= x do p = p * 2 end
		return p
	end

	-- Blake3.update.
	local function b3_update(h, b, n)
		if n == 0 then return end
		local pos, stop = 1, n + 1
		local c = h.chunk
		if chunk_len(c) > 0 then
			local take = math.min(CHUNK - chunk_len(c), n)
			chunk_update(c, b, pos, take)
			pos = pos + take
			if pos < stop then
				push_cv(h, chaining_value(chunk_output(c)), c.counter)
				h.chunk = chunk_init(h.key, c.flags, c.counter + 1)
				c = h.chunk
			else
				return
			end
		end
		while stop - pos > CHUNK do
			local subtree = round_down_pow2(stop - pos)
			local so_far = c.counter * CHUNK
			while so_far % subtree ~= 0 do subtree = subtree / 2 end
			local chunks = subtree / CHUNK
			if subtree <= CHUNK then
				local one = chunk_init(h.key, c.flags, c.counter)
				chunk_update(one, b, pos, subtree)
				push_cv(h, chaining_value(chunk_output(one)), one.counter)
			else
				local half = subtree / 2
				push_cv(h, subtree_cv(h, b, pos, half, c.counter), c.counter)
				push_cv(h, subtree_cv(h, b, pos + half, half, c.counter + chunks / 2), c.counter + chunks / 2)
			end
			c.counter = c.counter + chunks
			pos = pos + subtree
		end
		if pos < stop then
			chunk_update(c, b, pos, stop - pos)
			merge_cv_stack(h, c.counter)
		end
	end

	-- Blake3.final for a 32-byte digest (one root output block).
	local function b3_final(h)
		local output
		local remaining
		if #h.stack == 0 then
			output = chunk_output(h.chunk)
			remaining = 0
		elseif chunk_len(h.chunk) > 0 then
			remaining = #h.stack
			output = chunk_output(h.chunk)
		else
			remaining = #h.stack - 2
			output = parent_output(h.stack[remaining + 1], h.stack[remaining + 2], h.key, h.chunk.flags)
		end
		while remaining > 0 do
			output = parent_output(h.stack[remaining], chaining_value(output), h.key, h.chunk.flags)
			remaining = remaining - 1
		end
		compress_pre(output.cv, output.block, 1, output.len, 0, bor(output.flags, ROOT))
		local out = {}
		for i = 0, 7 do put_le32(out, 4 * i + 1, bxor(st[i], st[i + 8])) end
		return out
	end

	local function b3_init()
		return { key = B3_IV, chunk = chunk_init(B3_IV, 0, 0), stack = {} }
	end

	local B3_BASE = 1 + 32 + 32 + 8 + 64 + 1 + 1 + 1 + 1
	local B3_STACK_MAX = 55

	local function b3_serialize(h)
		if #h.stack > B3_STACK_MAX then invariant("bad BLAKE3 stack length") end
		local c = h.chunk
		local b = { 1 }
		for i = 1, 8 do put_le32(b, 2 + 4 * (i - 1), h.key[i]) end
		for i = 1, 8 do put_le32(b, 34 + 4 * (i - 1), c.cv[i]) end
		put_le64(b, 66, c.counter)
		for i = 1, 64 do b[73 + i] = i <= c.buf_len and c.buf[i] or 0 end
		b[138], b[139], b[140], b[141] = c.buf_len, c.blocks, c.flags, #h.stack
		for k, cv in ipairs(h.stack) do
			for i = 1, 8 do put_le32(b, B3_BASE + 32 * (k - 1) + 4 * (i - 1) + 1, cv[i]) end
		end
		local n = B3_BASE + 32 * #h.stack
		return (bytes_list(b, n))
	end

	local function words_at(b, at)
		local out = {}
		for i = 1, 8 do out[i] = get_le32(b, at + 4 * (i - 1)) end
		return out
	end

	local function b3_deserialize(l)
		if l[3] < B3_BASE then invariant("bad BLAKE3 state length") end
		local b = list_bytes(l)
		if b[1] ~= 1 then invariant("bad BLAKE3 state version") end
		local key = words_at(b, 2)
		local c = { cv = words_at(b, 34), counter = get_le64(b, 66), buf = {}, buf_len = b[138], blocks = b[139], flags = b[140] }
		for i = 1, 64 do c.buf[i] = b[73 + i] end
		if c.buf_len > 64 then invariant("bad BLAKE3 buffer length") end
		if c.blocks > 15 then invariant("bad BLAKE3 block count") end
		local depth = b[141]
		if depth > B3_STACK_MAX then invariant("bad BLAKE3 stack length") end
		if l[3] ~= B3_BASE + depth * DIGEST then invariant("bad BLAKE3 active stack byte length") end
		local stack = {}
		for k = 1, depth do stack[k] = words_at(b, B3_BASE + 32 * (k - 1) + 1) end
		return { key = key, chunk = c, stack = stack }
	end

	function M.blake3_hash_bytes(l)
		local h = b3_init()
		b3_update(h, list_bytes(l), l[3])
		return (bytes_list(b3_final(h), DIGEST))
	end
	function M.blake3_hasher_empty() return (b3_serialize(b3_init())) end
	function M.blake3_hasher_write(state, l)
		local h = b3_deserialize(state)
		b3_update(h, list_bytes(l), l[3])
		return (b3_serialize(h))
	end
	function M.blake3_hasher_finish(state) return (bytes_list(b3_final(b3_deserialize(state)), DIGEST)) end

	return M
end
