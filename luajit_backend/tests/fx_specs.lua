-- Print the fx platform IO specs from src/cli/test/fx_test_specs.zig as
-- NUL-terminated "<roc_file>\1<io_spec>" records (Zig string escapes resolved,
-- so a spec may contain newlines), omitting
-- specs marked `skip = true`. Usage: luajit fx_specs.lua FX_TEST_SPECS_ZIG
local source = assert(io.open(assert(arg[1]), "r")):read("*a")
local function unzig(s)
	return (s:gsub("\\(x%x%x)", function(h) return string.char(tonumber(h:sub(2), 16)) end)
		:gsub("\\(.)", { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["'"] = "'" }))
end
local count = 0
-- Each spec is one `.{ ... }` with `.roc_file` before `.io_spec`.
for file, body in source:gmatch('%.roc_file = "([^"]+)",(.-)\n%s*}') do
	local spec = body:match('%.io_spec = "(.-[^\\])",') or body:match('%.io_spec = "()",')
	if type(spec) == "string" and not body:match("%.skip = true") then
		io.write(file, "\1", unzig(spec), "\0")
		count = count + 1
	end
end
io.stderr:write(("fx_specs: %d specs\n"):format(count))
