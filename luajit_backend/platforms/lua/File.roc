import Lua

## Read and write files as UTF-8 text.
File :: [].{
	## What went wrong with a file operation.
	Error : [NotFound, PermissionDenied, IsADirectory, BadUtf8, Other(Str)]

	## The whole file at `path`.
	read_utf8! : Str => Try(Str, Error)
	read_utf8! = |path| {
		fields = Lua.call!("file_read", [Str(path)])
		Lua.when_ok(fields, |v| match v {
			Str(s) => Ok(s)
			_ => Err(BadUtf8)
		}, |rest| Err(error(rest)))
	}

	## Replace the file at `path` with `text` (creating it).
	write_utf8! : Str, Str => Try({}, Error)
	write_utf8! = |path, text| unit(Lua.call!("file_write", [Str(path), Str(text)]))

	## Append `text` to the file at `path` (creating it).
	append_utf8! : Str, Str => Try({}, Error)
	append_utf8! = |path, text| unit(Lua.call!("file_append", [Str(path), Str(text)]))

	## Delete the file at `path`.
	delete! : Str => Try({}, Error)
	delete! = |path| unit(Lua.call!("file_delete", [Str(path)]))

	unit : List((Lua.Value, Lua.Value)) -> Try({}, Error)
	unit = |fields| Lua.when_ok(fields, |_| Ok({}), |rest| Err(error(rest)))

	error : List((Lua.Value, Lua.Value)) -> Error
	error = |fields|
		match Lua.field_str(fields, "err") {
			"NotFound" => NotFound
			"PermissionDenied" => PermissionDenied
			"IsADirectory" => IsADirectory
			"BadUtf8" => BadUtf8
			other => Other(other)
		}
}
