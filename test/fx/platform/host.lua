-- LuaJIT host for the fx test platform (`roc build --target=luajit`), a port of
-- host.zig: Stdout/Stderr/Stdin line effects, the `--test`/`--test-verbose`
-- IO-spec mode, and host.zig's dbg, expect, crash and stack-overflow reports
-- and exit statuses. Hosted functions the port does not provide yet are absent,
-- so a program using them fails to load with the missing symbol's name.
local ffi = require("ffi")
ffi.cdef([[long read(int fd, void *buf, unsigned long count);]])

local M = {}

local function err(...) io.stderr:write(...) end

-- host_crash_handlers.zig's reports and exit statuses (128 + SIGABRT, 128 +
-- SIGFPE); stack_overflow is also the report for a Roc program that overflows.
local crash_reports = {
	stack_overflow = { "\nThis Roc application overflowed its stack memory and crashed.\n\n", 134 },
	division_by_zero = { "\nThis Roc application divided by zero and crashed.\n\n", 136 },
}
-- host.zig's self-test flags, which report a host crash without running Roc.
local self_test_flags = {
	["--host-test-stack-overflow"] = "stack_overflow",
	["--host-test-division-by-zero"] = "division_by_zero",
}

local function crash_exit(kind)
	local report = crash_reports[kind]
	io.stdout:flush()
	err(report[1])
	os.exit(report[2])
end

-- unescapeSpecValue: \n \t \r \\; any other backslash is kept.
local function unescape(s)
	return (s:gsub("\\(.?)", function(c)
		if c == "n" then return "\n" end
		if c == "t" then return "\t" end
		if c == "r" then return "\r" end
		if c == "\\" then return "\\" end
		return "\\" .. c
	end))
end

local kind_name = { stdin = "stdin", stdout = "stdout", stderr = "stderr" }

-- parseTestSpec: pipe-separated `0<`, `1>`, `2>` segments; empty segments
-- are skipped but still numbered.
local function parse_spec(spec)
	local entries, line = {}, 0
	for segment in (spec .. "|"):gmatch("([^|]*)|") do
		line = line + 1
		if #segment > 0 then
			local kind
			local p = segment:sub(1, 2)
			if p == "0<" then kind = "stdin" elseif p == "1>" then kind = "stdout" elseif p == "2>" then kind = "stderr" end
			if not kind then
				err("Error: Invalid spec segment '", segment, "' - must start with 0<, 1>, or 2>\n")
				return nil
			end
			entries[#entries + 1] = { kind = kind, value = unescape(segment:sub(3)), line = line }
		end
	end
	return entries
end

function M.run(app, argv)
	local spec, verbose, self_test
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--test-verbose" or a == "--test" then
			if i + 1 > #argv then
				err("Error: ", a, " requires a spec argument\n")
				os.exit(1)
			end
			i = i + 1
			spec, verbose = argv[i], a == "--test-verbose"
		elseif self_test_flags[a] then
			self_test = self_test_flags[a]
		elseif a:sub(1, 2) == "--" then
			err("Error: unknown flag '", a, "'\n")
			err("Usage: <app> [--test <spec>] [--test-verbose <spec>] [--host-test-stack-overflow] [--host-test-division-by-zero]\n")
			os.exit(1)
		end
		i = i + 1
	end
	-- host.zig triggers the self-test after reading every argument and before
	-- parsing the spec.
	if self_test then crash_exit(self_test) end

	local test = { enabled = false, entries = {}, index = 1, failed = false }
	if spec then
		local entries = parse_spec(spec)
		if not entries then
			err("HOST ERROR: InvalidSpecFormat\n")
			os.exit(1)
		end
		test.enabled, test.entries = true, entries
	end

	-- An output effect in test mode: consume a matching entry or record the
	-- first mismatch, as hostedStdoutLine/hostedStderrLine do.
	local function expect_output(kind, message)
		local entry = test.entries[test.index]
		if entry then
			if entry.kind == kind and entry.value == message then
				test.index = test.index + 1
				if verbose then err("[OK] ", kind, ": \"", message, "\"\n") end
				return
			end
			test.failed = true
			test.info = { expected = entry.kind, expected_value = entry.value, actual = kind, actual_value = message, line = entry.line }
			if verbose then err("[FAIL] ", kind, ": \"", message, "\" (expected ", kind_name[entry.kind], ": \"", entry.value, "\")\n") end
		else
			test.failed = true
			test.info = { expected = kind, expected_value = "", actual = kind, actual_value = message, line = 0 }
			if verbose then err("[FAIL] ", kind, ": \"", message, "\" (unexpected - no more expected operations)\n") end
		end
	end

	local rt
	local buffer = ffi.new("uint8_t[4096]")
	local hosted = {
		roc_stdout_line = function(s)
			if test.enabled then
				expect_output("stdout", s)
			else
				io.stdout:write(s, "\n")
			end
			return rt.ZST
		end,
		roc_stderr_line = function(s)
			if test.enabled then
				expect_output("stderr", s)
			else
				io.stdout:flush()
				err(s, "\n")
			end
			return rt.ZST
		end,
		-- One read(2) of up to 4096 bytes, first line kept (\n and a trailing
		-- \r trimmed), as host.zig's readStreaming does.
		roc_stdin_line = function()
			if test.enabled then
				local entry = test.entries[test.index]
				if entry and entry.kind == "stdin" then
					test.index = test.index + 1
					if verbose then err("[OK] stdin: \"", entry.value, "\"\n") end
					return entry.value
				end
				test.failed = true
				if entry then
					test.info = { expected = entry.kind, expected_value = entry.value, actual = "stdin", actual_value = "(stdin read)", line = entry.line }
					if verbose then err("[FAIL] stdin read (expected ", kind_name[entry.kind], ": \"", entry.value, "\")\n") end
				else
					test.info = { expected = "stdin", expected_value = "", actual = "stdin", actual_value = "(stdin read)", line = 0 }
					if verbose then err("[FAIL] stdin read (unexpected - no more expected operations)\n") end
				end
				return ""
			end
			io.stdout:flush()
			local n = tonumber(ffi.C.read(0, buffer, 4096))
			if n <= 0 then return "" end
			local line = ffi.string(buffer, n)
			local newline = line:find("\n", 1, true)
			if newline then line = line:sub(1, newline - 1) end
			if line:sub(-1) == "\r" then line = line:sub(1, -2) end
			return line
		end,
	}

	-- Records arrive as tables indexed by semantic field index: alphabetical by
	-- field name, unnamed `_` padding fields absent (host.zig instead reads the
	-- declared-order byte layout of Builder and Padded).
	hosted.roc_builder_print_value = function(builder)
		hosted.roc_stdout_line("SUCCESS: Builder.print_value! called via static dispatch!")
		hosted.roc_stdout_line("  value: " .. builder[2])
		hosted.roc_stdout_line("  count: " .. rt.u64_to_str(builder[1]))
		return rt.ZST
	end
	hosted.roc_host_get_greeting = function(host) return "Hello, " .. host[1] .. "!" end
	hosted.roc_padded_check = function(padded) return tostring(padded[2] * 100 + padded[1]) end
	-- The host owns the list and releases one unit of it (elements included).
	hosted.roc_host_sum_str_bytes = function(list)
		local total = 0
		for k = 0, list[3] - 1 do total = total + #rt.L.get_unsafe(list, k) end
		rt.L.decref(list, nil)
		return 0ULL + total
	end
	local stored_seed
	hosted.roc_host_store_seed = function(boxed)
		if stored_seed ~= nil then rt.crash("host was given a second seed while still holding one") end
		stored_seed = boxed
		return rt.ZST
	end
	hosted.roc_host_take_seed = function()
		local seed = stored_seed
		if seed == nil then rt.crash("host was asked for a seed it was never given") end
		stored_seed = nil
		return seed
	end

	-- Boxed erased callables across the host boundary (host.zig's Host.boxed_*
	-- family). A Box(I64 -> I64) is the runtime's erased callable
	-- { rc, proc, cap, drop }; host callables follow its ABI
	-- proc(args..., capture, reuse) and, like host.zig's, ignore the reuse slot.
	-- Drops are counted exactly where host.zig counts them.
	local drops
	local function reset_drops()
		drops = { primitive = 0, nested_record = 0, nested_str = 0, recursive_tree = 0, tree_child_boxes = 0, boxed_capture = 0, transition_outer = 0, transition_inner = 0, transition_nonnull = 0 }
	end
	reset_drops()
	local stored_boxed

	local function host_callable(proc, cap, drop) return { rc = 1, proc = proc, cap = cap, drop = drop } end
	-- callBoxedI64ToI64: borrow (reuse slot nil). consumeBoxedI64ToI64: hand
	-- the caller's reference to the callee through the reuse slot.
	local function call_boxed(boxed, x)
		if not boxed then rt.crash("host attempted to call a null boxed erased callable") end
		return boxed.proc(x, boxed.cap, nil)
	end
	local function consume_boxed(boxed, x)
		if not boxed then rt.crash("host attempted to call a null boxed erased callable") end
		return boxed.proc(x, boxed.cap, boxed)
	end

	hosted.roc_host_boxed_add = function(amount)
		return host_callable(function(x, cap) return x + cap.amount end, { amount = amount }, function() drops.primitive = drops.primitive + 1 end)
	end
	hosted.roc_host_boxed_nested_record = function(label)
		local cap = { label = label, base = 20LL, adjustment = 3LL }
		return host_callable(function(x, c) return x + c.base + c.adjustment + #c.label end, cap, function()
			drops.nested_str = drops.nested_str + 1
			drops.nested_record = drops.nested_record + 1
		end)
	end

	-- Tree := [Leaf(I64), Node(Box(Tree), Box(Tree))] arrives as
	-- {discriminant, payload}: Leaf = 0, Node = 1 with payload { left, right }
	-- of boxes { rc, v }.
	local function tree_clone(t)
		if t[1] == 0 then return { 0, t[2] } end
		return { 1, { { rc = 1, v = tree_clone(t[2][1].v) }, { rc = 1, v = tree_clone(t[2][2].v) } } }
	end
	local function tree_sum(t)
		if t[1] == 0 then return t[2] end
		return tree_sum(t[2][1].v) + tree_sum(t[2][2].v)
	end
	-- roc_builtins_box_decref_with on both children, counting the releases
	-- when `report` is set (hostTreeDropPayload vs ...WithoutReport).
	local function tree_drop(t, report)
		if t[1] ~= 1 then return end
		if report then drops.tree_child_boxes = drops.tree_child_boxes + 2 end
		for k = 1, 2 do rt.box_decref(t[2][k], function(v) tree_drop(v, report) end) end
	end
	hosted.roc_host_boxed_recursive_tree = function(tree)
		local cap = { tree = tree_clone(tree) }
		tree_drop(tree, false)
		return host_callable(function(x, c) return x + tree_sum(c.tree) end, cap, function(c)
			tree_drop(c.tree, true)
			drops.recursive_tree = drops.recursive_tree + 1
		end)
	end

	hosted.roc_host_boxed_with_boxed_capture = function(inner, bonus)
		if not inner then rt.crash("host boxed callable capture received null inner callable") end
		rt.erased_incref(inner, 1)
		rt.erased_decref(inner)
		return host_callable(function(x, c) return call_boxed(c.inner, x) + c.bonus end, { inner = inner, bonus = bonus }, function(c)
			rt.erased_decref(c.inner)
			drops.boxed_capture = drops.boxed_capture + 1
		end)
	end
	hosted.roc_host_call_boxed = function(boxed, x) return consume_boxed(boxed, x) end

	-- The outer callable repacks its reuse slot into the inner one
	-- (erased_callable.repack, .Immutable). `{} -> ...` callables take the
	-- unit argument explicitly, as emitted calls pass every argument local.
	local function inner_drop() drops.transition_inner = drops.transition_inner + 1 end
	hosted.roc_host_boxed_transition = function(value)
		return host_callable(function(_, cap, reuse)
			if reuse ~= nil then drops.transition_nonnull = drops.transition_nonnull + 1 end
			return rt.erased_pack(function(_, c) return c.value end, { value = cap.value }, inner_drop, reuse, false)
		end, { value = value }, function() drops.transition_outer = drops.transition_outer + 1 end)
	end
	-- callBoxedTransitionWithoutReuse: call outer then inner without reuse,
	-- releasing both afterwards.
	hosted.roc_host_call_boxed_transition = function(boxed)
		if not boxed then rt.crash("host attempted to call a null boxed transition") end
		local inner = boxed.proc(rt.ZST, boxed.cap, nil)
		if not inner then rt.crash("boxed transition returned a null boxed callable") end
		local result = inner.proc(rt.ZST, inner.cap, nil)
		rt.erased_decref(inner)
		rt.erased_decref(boxed)
		return result
	end

	hosted.roc_host_roundtrip_boxed = function(boxed)
		if boxed then
			rt.erased_incref(boxed, 1)
			rt.erased_decref(boxed)
		end
		return boxed
	end
	hosted.roc_host_store_boxed = function(boxed)
		if stored_boxed then
			rt.erased_decref(stored_boxed)
			stored_boxed = nil
		end
		if not boxed then rt.crash("host attempted to store a null boxed erased callable") end
		rt.erased_incref(boxed, 1)
		stored_boxed = boxed
		rt.erased_decref(boxed)
		return rt.ZST
	end
	hosted.roc_host_stored_boxed_call = function(x) return call_boxed(stored_boxed, x) end
	hosted.roc_host_release_stored_boxed = function()
		if stored_boxed then
			rt.erased_decref(stored_boxed)
			stored_boxed = nil
		end
		return rt.ZST
	end
	hosted.roc_host_boxed_drop_report = function()
		return ("drops primitive=%d nested_record=%d nested_str=%d recursive_tree=%d tree_child_boxes=%d boxed_capture=%d transition_outer=%d transition_inner=%d transition_nonnull=%d"):format(
			drops.primitive, drops.nested_record, drops.nested_str, drops.recursive_tree, drops.tree_child_boxes,
			drops.boxed_capture, drops.transition_outer, drops.transition_inner, drops.transition_nonnull)
	end
	hosted.roc_host_reset_boxed_drop_report = function()
		if stored_boxed then
			rt.erased_decref(stored_boxed)
			stored_boxed = nil
		end
		reset_drops()
		return rt.ZST
	end

	local program = app(hosted)
	rt = program.rt
	rt.on_dbg = function(message) err("ROC DBG: ", message, "\n") end
	rt.on_expect_failed = function(message)
		err("Expect failed: ", (message:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", "")), "\n")
		os.exit(1)
	end

	local ok, message, failure = rt.call_entry(program.entrypoints.roc_main)
	io.stdout:flush()
	if failure == "stack_overflow" then crash_exit("stack_overflow") end
	if not ok then
		err("\n\27[31mRoc crashed:\27[0m ", message, "\n")
		os.exit(1)
	end

	if test.enabled and (test.failed or test.index ~= #test.entries + 1) then
		local info = test.info
		if info then
			if info.line == 0 then
				err("TEST FAILED: Unexpected ", kind_name[info.actual], " output: \"", info.actual_value, "\"\n")
			else
				err(("TEST FAILED at spec line %d:\n  Expected: %s \"%s\"\n  Got:      %s \"%s\"\n"):format(
					info.line, kind_name[info.expected], info.expected_value, kind_name[info.actual], info.actual_value))
			end
		else
			local remaining = #test.entries - test.index + 1
			err(("TEST FAILED: %d expected IO operation(s) not performed:\n"):format(remaining))
			for k = test.index, math.min(#test.entries, test.index + 4) do
				local entry = test.entries[k]
				err("  - ", kind_name[entry.kind], ": \"", entry.value, "\"\n")
			end
			if remaining > 5 then err("  ...\n") end
		end
		os.exit(1)
	end
	if rt.inline_expect_failed then os.exit(1) end
	os.exit(0)
end

return M
