//! Native host of the Lua platform: embeds LuaJIT and this directory's
//! host.lua, and answers the platform's one hosted call by forwarding its
//! bytes to host.lua's core (`M.new(M.default_ports).dispatch`), so a native
//! build runs every effect through the same Lua code as a `--target=luajit`
//! build. Built by `build-host` (outside build.zig) from fx-open's host.
const std = @import("std");
const Allocator = std.mem.Allocator;
const shim_io = @import("shim_io");
const builtins = @import("builtins");
const host_alloc = @import("host_alloc");

pub const std_options_elf_debug_info_search_paths = shim_io.elfDebugInfoSearchPaths;
pub const std_options_debug_io = shim_io.io();
pub const std_options_debug_threaded_io = null;
pub const std_options = shim_io.std_options_static_archive;

const RocStr = builtins.str.RocStr;
const RocList = builtins.list.RocList;
const RocOps = builtins.host_abi.RocOps;

const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{ .thread_safe = false }),

    pub fn rocAllocator(self: *HostEnv) Allocator {
        return self.gpa.allocator();
    }
};
const callbacks = host_alloc.Callbacks(HostEnv);

// LuaJIT's C API (lua.h, lauxlib.h, lualib.h), only what the host uses.
const lua_State = opaque {};
extern fn luaL_newstate() ?*lua_State;
extern fn luaL_openlibs(L: *lua_State) void;
extern fn luaL_loadbuffer(L: *lua_State, buf: [*]const u8, size: usize, name: [*:0]const u8) c_int;
extern fn lua_pcall(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int;
extern fn lua_pushlstring(L: *lua_State, s: [*]const u8, len: usize) void;
extern fn lua_tolstring(L: *lua_State, idx: c_int, len: *usize) ?[*]const u8;
extern fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
extern fn lua_settop(L: *lua_State, idx: c_int) void;
extern fn lua_rawgeti(L: *lua_State, idx: c_int, n: c_int) void;
extern fn luaL_ref(L: *lua_State, t: c_int) c_int;
extern fn fflush(stream: ?*anyopaque) c_int;
const LUA_REGISTRYINDEX: c_int = -10000;

const host_lua = @embedFile("host.lua");

var g_roc_ops: ?*RocOps = null;
var g_lua: ?*lua_State = null;
var g_dispatch: c_int = 0;

fn fail(L: *lua_State, what: []const u8) noreturn {
    var len: usize = 0;
    const msg = lua_tolstring(L, -1, &len);
    std.debug.print("Lua platform host: {s}: {s}\n", .{ what, if (msg) |m| m[0..len] else "(no message)" });
    std.process.exit(1);
}

/// The Lua state and host.lua's dispatch function, created on first use.
fn luaState() *lua_State {
    if (g_lua) |L| return L;
    const L = luaL_newstate() orelse {
        std.debug.print("Lua platform host: out of memory creating the Lua state\n", .{});
        std.process.exit(1);
    };
    luaL_openlibs(L);
    if (luaL_loadbuffer(L, host_lua.ptr, host_lua.len, "=host.lua") != 0) fail(L, "loading host.lua");
    if (lua_pcall(L, 0, 1, 0) != 0) fail(L, "running host.lua");
    lua_getfield(L, -1, "new");
    lua_getfield(L, -2, "default_ports");
    if (lua_pcall(L, 1, 1, 0) != 0) fail(L, "creating the platform core");
    lua_getfield(L, -1, "dispatch");
    g_dispatch = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_settop(L, 0);
    g_lua = L;
    return L;
}

/// Hosted function Host.call!: consumes `op` and `request`, returns the
/// response bytes host.lua's core produced.
fn hostedCall(op: RocStr, request: RocList) callconv(.c) RocList {
    const ops = g_roc_ops.?;
    var owned_op = op;
    defer owned_op.decref(ops);
    defer request.decref(1, 1, false, null, builtins.utils.rcNone, ops);
    const L = luaState();
    lua_rawgeti(L, LUA_REGISTRYINDEX, g_dispatch);
    const op_bytes = owned_op.asSlice();
    lua_pushlstring(L, op_bytes.ptr, op_bytes.len);
    const n = request.len();
    if (request.elements(u8)) |bytes| lua_pushlstring(L, bytes, n) else lua_pushlstring(L, "", 0);
    if (lua_pcall(L, 2, 1, 0) != 0) fail(L, "platform call");
    var len: usize = 0;
    const response = lua_tolstring(L, -1, &len) orelse fail(L, "platform call returned no bytes");
    const out = RocList.list_allocate(1, len, 1, false, ops);
    if (out.elements(u8)) |dest| @memcpy(dest[0..len], response[0..len]);
    lua_settop(L, 0);
    return out;
}

extern fn roc_main(args: RocList) callconv(.c) i32;

fn rocExpectFailedFn(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    std.debug.print("Expect failed: {s}\n", .{std.mem.trim(u8, bytes[0..len], " \t\n\r")});
}

fn rocCrashedFn(_: *RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = fflush(null);
    std.debug.print("Roc crashed: {s}\n", .{bytes[0..len]});
    std.process.exit(1);
}

fn getOps() *RocOps {
    return g_roc_ops.?;
}

comptime {
    @export(&main, .{ .name = "main" });
    @export(&hostedCall, .{ .name = "lua_platform_host_call", .visibility = .hidden });
    host_alloc.exportRuntimeSymbols(getOps, .{});
}

/// The arguments after the program name, as a List(Str) (what host.lua
/// passes too, from LuaJIT's `arg`).
fn buildArgsList(ops: *RocOps, argc: c_int, argv: [*][*:0]u8) RocList {
    const count: usize = @intCast(argc);
    if (count <= 1) return RocList.empty();
    const list = RocList.list_allocate(@alignOf(RocStr), count - 1, @sizeOf(RocStr), true, ops);
    const items: [*]RocStr = @ptrCast(@alignCast(list.bytes));
    for (1..count) |i| items[i - 1] = RocStr.fromSlice(std.mem.span(argv[i]), ops);
    return list;
}

fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    var host_env = HostEnv{ .gpa = .{} };
    var roc_ops = RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = callbacks.rocAllocFn,
        .roc_dealloc = callbacks.rocDeallocFn,
        .roc_realloc = callbacks.rocReallocFn,
        .roc_dbg = callbacks.rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{ .count = 0, .fns = undefined },
    };
    g_roc_ops = &roc_ops;
    const status = roc_main(buildArgsList(&roc_ops, argc, argv));
    _ = fflush(null);
    return status;
}
