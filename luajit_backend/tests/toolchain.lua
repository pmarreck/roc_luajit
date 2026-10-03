-- Bootstrap evidence only. These checks do not test a Roc LuaJIT emitter.
assert(_VERSION == "Lua 5.1")
assert(jit and jit.version_num >= 20100)
local ffi = require("ffi")
local bit = require("bit")
assert(ffi.sizeof("uint64_t") == 8)
assert(bit.bxor(0x55, 0xff) == 0xaa)
