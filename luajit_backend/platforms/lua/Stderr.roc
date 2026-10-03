import Lua

## Write to standard error.
Stderr :: [].{
	## Write `text` and a newline.
	line! : Str => {}
	line! = |text| {
		_ = Lua.call!("stderr_line", [Str(text)])
		{}
	}

	## Write `text` as it is.
	write! : Str => {}
	write! = |text| {
		_ = Lua.call!("stderr_write", [Str(text)])
		{}
	}
}
