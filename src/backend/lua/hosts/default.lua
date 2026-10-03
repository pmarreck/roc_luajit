-- LuaJIT host for Roc's default platform (headerless apps built with
-- `roc build --target=luajit`). It mirrors src/default_platform/linux_runtime.zig
-- running echo_platform's `build_platform_main_source`: the process arguments
-- without argv[0] go to `roc_default_start_main`, whose I32 is the exit status;
-- a failed inline expect turns status 0 into 1; a crash prints the native
-- runtime's message and exits 1. (The native runtime also prints a backtrace,
-- which has no LuaJIT counterpart.)
local M = {}

function M.run(app, argv)
	local rt
	local hosted = {
		roc_default_echo_line = function(s)
			io.stdout:write(s)
			return rt.ZST
		end,
	}
	local program = app(hosted)
	rt = program.rt
	local strings = {}
	for i = 1, #argv do strings[i] = argv[i] end
	local ok, status, failure = rt.call_entry(program.entrypoints.roc_default_start_main, rt.host_str_list(strings))
	io.stdout:flush()
	if failure == "stack_overflow" then
		io.stderr:write("Roc application overflowed its stack memory\n\n")
		os.exit(1)
	end
	if not ok then
		io.stderr:write("Roc application crashed with this message:\n\n\t", status, "\n\n")
		os.exit(1)
	end
	if status == 0 and rt.inline_expect_failed then os.exit(1) end
	os.exit(status)
end

return M
