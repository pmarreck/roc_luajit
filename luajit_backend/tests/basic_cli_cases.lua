-- Runs basic-cli's test cases (luajit_backend/demos/basic-cli/scripts/
-- test_spec.json) against apps that basic_cli_conformance already built, native
-- and LuaJIT, and compares the runs. A case agrees when both runs have the same
-- exit status, stdout and stderr, and the LuaJIT run also meets upstream's own
-- assertions (exit_code, contains, regex, stdout_/stderr_contains), as
-- basic-cli's scripts/test.py checks them. Cases listed in `spec_only` print
-- values that differ between any two runs (a random seed, the clock, a fresh
-- temporary path, the program's own path); they are judged by the exit status
-- and upstream's assertions alone. Where the native run itself fails
-- upstream's assertions (basic-cli's native host crashes on some process
-- cases), those assertions alone judge the LuaJIT run (spec_only). Every
-- run happens in a private network namespace (scripts/netns_run): the
-- examples reach localhost:9000 and :8085, and this machine's own services
-- must never receive their requests. Cases that name a helper server
-- (upstream's TCP echo and HTTP test servers) get it in the same namespace
-- (scripts/with_helper). Cases marked `pty` run on a pseudo-terminal
-- (scripts/pty_run), as upstream's test.py runs them.
--
-- Each run sees a fresh copy of the corpus (timestamps preserved) at the same
-- path, and temp_cwd cases a fresh empty directory at the same path, so
-- paths printed by the two runs agree.
--
-- Usage: luajit basic_cli_cases.lua WORK CORPUS [candidate=luajit|wasm] [max-unsupported=N] [FILTER]
-- WORK/build/<app name>/{native,app.lua or app.wasm,built} come from
-- basic_cli_conformance. The candidate is the LuaJIT build (default) or the
-- wasm32 build on the WASI platform, run by wasmtime with the host's root
-- directory and environment.
-- Exit status: diverging cases, plus 1 if the unsupported count exceeds the
-- ratchet.
local cjson = require("cjson")

local work, corpus = assert(arg[1], "work dir"), assert(arg[2], "corpus dir")
local max_unsupported, filter
local candidate = "luajit"
for i = 3, #arg do
	local n = arg[i]:match("^max%-unsupported=(%d+)$")
	local c = arg[i]:match("^candidate=(%a+)$")
	if n then max_unsupported = tonumber(n) elseif c then candidate = c else filter = arg[i] end
end
assert(candidate == "luajit" or candidate == "wasm", "candidate must be luajit or wasm")
local CANDIDATE = candidate == "wasm" and "wasm" or "LuaJIT"
-- The command running a built candidate, and the name of a hosted function
-- it reports missing (the LuaJIT host's loader, or wasmtime's unknown import).
local function candidate_command(build)
	-- argv[0] is the module's full path, as a native program sees its own.
	if candidate == "wasm" then return ("wasmtime run -S inherit-env=y --dir=/ --argv0 '%s' '%s'"):format(build .. "/app.wasm", build .. "/app.wasm") end
	return "luajit " .. ("'%s'"):format(build .. "/app.lua")
end
local function missing_hosted(err)
	return err:match("does not provide hosted function ([%w_]+)")
end

-- Cases whose output legitimately differs between two runs of one binary.
local spec_only = {
	["examples/random.roc"] = "prints random values",
	["examples/time.roc"] = "prints elapsed time",
	["examples/temp-dir.roc"] = "prints a fresh temporary directory",
	["examples/command-line-args.roc"] = "prints the program's own path",
	["examples/file-accessed-modified-created-time.roc"] = "prints the birth time of a fresh copy",
}

-- Cases the WASI host cannot run as native does, because WASI preview1 lacks
-- what they need. They count as unsupported, with the reason.
local wasi_limits = {
	["examples/file-permissions.roc"] = "WASI exposes no permission bits (File.is_executable!)",
	["examples/check-command.roc"] = "WASI exposes no permission bits (it looks for executables on PATH)",
	["apps/path_copy_mode.roc"] = "WASI exposes no permission bits (Path.is_executable!)",
}

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
local function write(path, s)
	local f = assert(io.open(path, "wb"))
	f:write(s)
	f:close()
end
local function run(cmd)
	local ok = os.execute(cmd)
	return ok == 0 or ok == true
end
local function from_hex(h) return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end)) end

local spec = cjson.decode(assert(read(corpus .. "/scripts/test_spec.json")))

-- Upstream's verify_text: CRLF/CR normalized; substrings, then PCRE searches
-- (MULTILINE), run by ripgrep since Lua patterns cannot express them.
local function check_text(label, output, contains, regexes, failures)
	local normalized = output:gsub("\r\n", "\n"):gsub("\r", "\n")
	if normalized:find("[ROC CRASHED]", 1, true) then failures[#failures + 1] = label .. ": runtime crash" end
	for _, expected in ipairs(contains or {}) do
		if not normalized:find(expected, 1, true) then
			failures[#failures + 1] = ("%s: missing %q"):format(label, expected)
		end
	end
	for _, pattern in ipairs(regexes or {}) do
		local file = work .. "/regex_input"
		write(file, normalized)
		if not run(("rg -U --pcre2 -q -e %s %s"):format(sh_quote(pattern), sh_quote(file))) then
			failures[#failures + 1] = ("%s: no match for /%s/"):format(label, pattern)
		end
	end
end

local function check_spec(case, result)
	local failures = {}
	local expected_exit = case.exit_code or 0
	if result.rc ~= expected_exit then failures[#failures + 1] = ("exit %d, expected %d"):format(result.rc, expected_exit) end
	check_text("combined output", result.out .. result.err, case.contains, case.regex, failures)
	check_text("stdout", result.out, case.stdout_contains, case.stdout_regex, failures)
	check_text("stderr", result.err, case.stderr_contains, case.stderr_regex, failures)
	return failures
end

-- One run of `exe` (a command prefix) for `case`, in a fresh corpus copy.
local function script(name)
	local h = assert(io.popen("realpath " .. sh_quote((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../scripts/" .. name)))
	local path = h:read("*l")
	h:close()
	return sh_quote(assert(path, name .. " not found"))
end
local netns_run, with_helper, pty_run = script("netns_run"), script("with_helper"), script("pty_run")
local function run_case(app, case, base, exe)
	local root, cwd = base .. "/root", base .. "/cwd"
	assert(run(("rm -rf %s %s && cp -a %s %s"):format(sh_quote(root), sh_quote(cwd), sh_quote(corpus), sh_quote(root))))
	local function expand(v)
		-- {python}: upstream's cases run small helper scripts as child processes.
		return (v:gsub("{root}", root):gsub("{source}", root .. "/" .. app.path):gsub("{source_dir}", (root .. "/" .. app.path):match("^(.*)/")):gsub("{python}", "python3"))
	end
	if case.temp_cwd then assert(run("mkdir -p " .. sh_quote(cwd))) else cwd = root end
	for _, fixture in ipairs(case.fixtures or {}) do
		assert(run(("cp %s %s"):format(sh_quote(root .. "/" .. fixture.source), sh_quote(root .. "/" .. fixture.target))))
	end
	write(base .. "/stdin", case.stdin_hex and from_hex(case.stdin_hex) or (case.stdin or ""))
	local env = {}
	for _, name in ipairs(case.unset_env or {}) do env[#env + 1] = "-u " .. sh_quote(name) end
	for name, value in pairs(case.env or {}) do env[#env + 1] = sh_quote(name .. "=" .. expand(value)) end
	local args = {}
	for _, a in ipairs(case.args or {}) do args[#args + 1] = sh_quote(expand(a)) end
	-- A helper server (case.helper) runs beside the program in its namespace.
	-- The dns helper answers names only inside a private resolver setup.
	local isolate = netns_run .. (case.helper == "dns" and " --private-dns" or "")
		.. (case.helper and (" " .. with_helper .. " " .. sh_quote(case.helper)) or "")
	-- A pty case (case.pty) runs on a terminal that pty_run types its stdin
	-- into; everything the program writes is the terminal's output (stdout).
	local runner = case.pty
		and ("%s %s %d %s --"):format(pty_run, sh_quote(base .. "/stdin"), case.timeout or 7, tostring(case.input_delay or 0.08))
		or ("timeout %d"):format(case.timeout or 7)
	local cmd = ("cd %s && %s env %s %s %s %s <%s >%s 2>%s; echo $? >%s"):format(
		sh_quote(cwd), isolate, table.concat(env, " "), runner, exe, table.concat(args, " "),
		sh_quote(base .. "/stdin"), sh_quote(base .. "/out"), sh_quote(base .. "/err"), sh_quote(base .. "/rc"))
	-- bash's own report of a signal-killed program goes to a file.
	run("bash -c " .. sh_quote(cmd) .. " 2>" .. sh_quote(base .. "/shell"))
	return { out = read(base .. "/out") or "", err = read(base .. "/err") or "", rc = tonumber(read(base .. "/rc")) }
end

local counts = { agreed = 0, diverged = 0, spec_only = 0, unsupported = 0, skipped = 0 }
local unsupported_names = {}
local function report(kind, app, case, detail)
	counts[kind] = counts[kind] + 1
	if kind ~= "agreed" then print(("  %s %s [%s]: %s"):format(kind, app.path, case.name, detail)) end
end

for _, app in ipairs(spec.apps) do
	local linux = (app.platforms or {}).linux or {}
	if linux.run ~= false and (not filter or app.path:find(filter, 1, true)) then
		local name = app.path:match("([^/]+)%.roc$")
		local build = work .. "/build/" .. name
		local built = (read(build .. "/built") or ""):match("%S+")
		for _, case in ipairs(app.cases or {}) do
			local base = work .. "/cases/" .. name .. "/" .. case.name
			assert(run("mkdir -p " .. sh_quote(base)))
			if candidate == "wasm" and wasi_limits[app.path] and built == "both" then
				report("unsupported", app, case, wasi_limits[app.path])
			elseif built ~= "both" and built ~= "native-only" then
				report("skipped", app, case, "native build failed")
			elseif built == "native-only" then
				report("unsupported", app, case, CANDIDATE .. " build failed: " .. ((read(build .. "/lb.err") or ""):match("[^\n]*[Ee]rror[^\n]*") or "?"):sub(1, 160))
			else
				local native = run_case(app, case, base, sh_quote(build .. "/native"))
				local native_failures = check_spec(case, native)
				local lua = run_case(app, case, base, candidate_command(build))
				-- A pty case's stderr reaches the terminal, which is its stdout.
				local missing = missing_hosted(lua.err) or (case.pty and missing_hosted(lua.out))
				if missing then
					unsupported_names[missing] = true
					report("unsupported", app, case, "no hosted function " .. missing)
				elseif #native_failures > 0 then
					-- Upstream's assertions still judge the LuaJIT run.
					local lua_failures = check_spec(case, lua)
					if #lua_failures == 0 then
						report("spec_only", app, case, "native run fails upstream's spec (" .. native_failures[1] .. "); " .. CANDIDATE .. " run meets it")
					else
						report("skipped", app, case, "neither run meets upstream's spec: native " .. native_failures[1] .. "; " .. CANDIDATE .. " " .. lua_failures[1])
					end
				else
					local failures = check_spec(case, lua)
					if not spec_only[app.path] then
						if lua.rc ~= native.rc then failures[#failures + 1] = ("exit native=%d %s=%d"):format(native.rc, candidate, lua.rc) end
						if lua.out ~= native.out then failures[#failures + 1] = "stdout differs: native " .. ("%q"):format(native.out:sub(1, 200)) .. " " .. candidate .. " " .. ("%q"):format(lua.out:sub(1, 200)) end
						if lua.err ~= native.err then failures[#failures + 1] = "stderr differs: native " .. ("%q"):format(native.err:sub(1, 200)) .. " " .. candidate .. " " .. ("%q"):format(lua.err:sub(1, 200)) end
					end
					if #failures == 0 then report("agreed", app, case) else report("diverged", app, case, table.concat(failures, "; ")) end
				end
			end
		end
	end
end

local names = {}
for n in pairs(unsupported_names) do names[#names + 1] = n end
table.sort(names)
if #names > 0 then print("  hosted functions still missing: " .. table.concat(names, ", ")) end
print(("basic_cli_conformance: %d agreed, %d diverged, %d meet upstream's spec where the native run does not, %d unsupported, %d skipped"):format(
	counts.agreed, counts.diverged, counts.spec_only, counts.unsupported, counts.skipped))
local status = counts.diverged
if max_unsupported and counts.unsupported > max_unsupported then
	print(("basic_cli_conformance: unsupported %d exceeds the ratchet %d"):format(counts.unsupported, max_unsupported))
	status = status + 1
end
os.exit(status)
