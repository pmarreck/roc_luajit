## Build file paths (as `Str`, which is what File takes).
Path :: [].{
	## `dir` and `name` joined by one `/`.
	join : Str, Str -> Str
	join = |dir, name|
		if dir == "" name
		else if dir.ends_with("/") Str.concat(dir, name)
		else "${dir}/${name}"
}
