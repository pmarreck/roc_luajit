import Lua

## Read from standard input.
Stdin :: [].{
	## The next line without its newline; `EndOfFile` once input is exhausted,
	## `BadUtf8` for a line that is not valid UTF-8.
	line! : () => Try(Str, [EndOfFile, BadUtf8])
	line! = || {
		fields = Lua.call!("stdin_line", [])
		Lua.when_ok(fields, |v| match v {
			Str(s) => Ok(s)
			_ => Err(BadUtf8)
		}, |rest| if Lua.field_true(rest, "eof") Err(EndOfFile) else Err(BadUtf8))
	}
}
