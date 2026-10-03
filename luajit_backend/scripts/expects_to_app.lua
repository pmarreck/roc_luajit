-- Turn a headerless Roc file of top-level `expect`s (an exercism test file)
-- into an app: each top-level `expect EXPR` becomes `exercism_test_N = |_| EXPR`
-- and an appended `main!` prints `test N: <Str.inspect of its result>` per
-- test. A top-level expect starts at column 0; its expression continues on
-- the following indented lines (or column-0 closers such as `}`) up to the
-- next other column-0 line. An expression that uses `?` needs a Try-returning
-- context, so it becomes `|_| Ok(EXPR)` and an early `Err` prints as such.
--
-- Usage: luajit expects_to_app.lua TEST.roc > APP.roc
local path = assert(arg[1], "usage: expects_to_app.lua TEST.roc")
local out, n = {}, 0
local test -- lines of the expect being read, or nil

local function uses_try(lines)
	for _, l in ipairs(lines) do
		if l:find("[%w_%)%]}]%?") then return true end
	end
	return false
end

local function flush()
	if not test then return end
	-- Trailing blank and comment lines belong to what follows.
	local tail = {}
	while #test > 1 and (test[#test]:match("^%s*$") or test[#test]:match("^%s*#")) do
		table.insert(tail, 1, table.remove(test))
	end
	local head = ("exercism_test_%d = |_|"):format(n)
	local rest = test[1]
	if uses_try(test) then
		test[1] = head .. " Ok(" .. (rest == "" and "" or rest)
		test[#test + 1] = ")"
	else
		test[1] = head .. (rest == "" and "" or " " .. rest)
	end
	for _, l in ipairs(test) do out[#out + 1] = l end
	for _, l in ipairs(tail) do out[#out + 1] = l end
	test = nil
end

for line in io.lines(path) do
	local rest = line:match("^expect%s+(.*)$") or (line == "expect" and "")
	if rest then
		flush()
		n = n + 1
		test = { rest }
	elseif test and (line == "" or line:match("^[%s%)%]}]")) then
		test[#test + 1] = line
	else
		flush()
		out[#out + 1] = line
	end
end
flush()
out[#out + 1] = ""
out[#out + 1] = "main! = |_args| {"
for i = 1, n do
	out[#out + 1] = ('    echo!("test %d: ${Str.inspect(exercism_test_%d({}))}\\n")'):format(i, i)
end
out[#out + 1] = "    Ok({})"
out[#out + 1] = "}"
io.write(table.concat(out, "\n"), "\n")
