## The platform's single hosted effect: run platform op `op` on a request
## encoded as LuaValue bytes and return the encoded response. Both hosts
## answer it with the same platform.lua.
Host :: [].{
	call! : Str, List(U8) => List(U8)
}
