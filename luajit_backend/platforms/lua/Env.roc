import Lua

## The process environment.
Env :: [].{
	## The value of environment variable `name`; `VarNotFound` when unset,
	## `BadUtf8` when its value is not valid UTF-8.
	var! : Str => Try(Str, [VarNotFound, BadUtf8])
	var! = |name| {
		fields = Lua.call!("env_var", [Str(name)])
		Lua.when_ok(fields, |v| match v {
			Str(s) => Ok(s)
			_ => Err(BadUtf8)
		}, |rest| if Lua.field_true(rest, "missing") Err(VarNotFound) else Err(BadUtf8))
	}
}
