import Lua

## Write to standard output.
Stdout :: [].{
	## Write `text` and a newline.
	line! : Str => {}
	line! = |text| {
		_ = Lua.call!("stdout_line", [Str(text)])
		{}
	}

	## Write `text` as it is.
	write! : Str => {}
	write! = |text| {
		_ = Lua.call!("stdout_write", [Str(text)])
		{}
	}
}
