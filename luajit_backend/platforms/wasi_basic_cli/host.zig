//! WASI host for basic-cli 0.23.0: implements basic-cli's hosted functions on
//! WASI preview1 (wasi_snapshot_preview1 imports) so a basic-cli app built with
//! `--target=wasm32` runs under a WASI runtime such as wasmtime. Behavior follows
//! basic-cli's Rust host (and its LuaJIT port, src/backend/lua/hosts/
//! basic_cli_0_23_0.lua): the same results, errors, messages and exit codes.
//! Value layouts and ownership come from glue generated for this platform
//! (`abi`, roc_platform_abi.zig); hosted functions consume their arguments.
//! Hosted functions WASI cannot provide (processes, sockets, terminals) are not
//! defined here, so a program using one fails to instantiate and the runtime
//! names the missing import.
const std = @import("std");
const abi = @import("abi");
const shim_symbols = @import("shim_symbols");
const wasi = std.os.wasi;

var env: abi.RocEnv = undefined;
var host: abi.RocHost = undefined;
/// Set by roc_dbg and roc_expect_failed: a successful exit becomes status 1.
var debug_or_expect = false;

const wasi_io = abi.RocIo{ .ctx = null, .vtable = &.{ .writeStderr = ioWriteStderr, .onFatal = ioFatal } };
fn ioWriteStderr(_: ?*anyopaque, data: []const u8) void {
	_ = writeAll(2, data);
}
fn ioFatal(_: ?*anyopaque) noreturn {
	wasi.proc_exit(1);
}

// Runtime symbols ------------------------------------------------------------

comptime {
	shim_symbols.exportRuntimeFns(.{
		.alloc = &rocAlloc,
		.dealloc = &rocDealloc,
		.realloc = &rocRealloc,
		.dbg = &rocDbg,
		.expect_failed = &rocExpectFailed,
		.crashed = &rocCrashed,
	}, .default);
}

// Roc code and the glue helpers share one allocation scheme (the glue's
// size-prefixed DefaultAllocators over wasm_allocator), so either side can
// free what the other allocated.
fn rocAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
	return abi.DefaultAllocators.rocAlloc(&host, length, alignment);
}
fn rocDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
	hostDealloc(&host, ptr, alignment);
}
/// The glue helpers' deallocation too (host.roc_dealloc), so freeing a file
/// reader's box closes its file wherever the last reference is dropped.
fn hostDealloc(h: *abi.RocHost, ptr: *anyopaque, alignment: usize) callconv(.c) void {
	if (reader_boxes.count() > 0) {
		if (reader_boxes.fetchRemove(@intFromPtr(ptr))) |entry| closeReader(entry.value);
	}
	abi.DefaultAllocators.rocDealloc(h, ptr, alignment);
}
fn rocRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
	return abi.DefaultAllocators.rocRealloc(&host, ptr, new_length, alignment);
}
fn rocDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
	debug_or_expect = true;
	_ = writeAll(2, "[ROC DBG] ");
	_ = writeAll(2, bytes[0..len]);
	_ = writeAll(2, "\n");
}
fn rocExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
	debug_or_expect = true;
	_ = writeAll(2, "[ROC EXPECT] ");
	_ = writeAll(2, bytes[0..len]);
	_ = writeAll(2, "\n");
}
fn rocCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
	_ = writeAll(2, "[ROC CRASHED] ");
	_ = writeAll(2, bytes[0..len]);
	_ = writeAll(2, "\n");
	wasi.proc_exit(1);
}

// Entry point ----------------------------------------------------------------

var program_name: []const u8 = "";

/// The WASI command entry point: main_for_host! receives the arguments after
/// argv[0] as UnixBytes OsStrs; its I32 result is the exit status.
export fn _start() void {
	env = .{ .allocator = std.heap.wasm_allocator, .roc_io = wasi_io };
	host = abi.makeRocHost(&env);
	host.roc_dealloc = &hostDealloc;
	var argc: usize = 0;
	var buf_size: usize = 0;
	if (wasi.args_sizes_get(&argc, &buf_size) != .SUCCESS) fatal("cannot read the command-line arguments");
	const argv = std.heap.wasm_allocator.alloc([*:0]u8, argc) catch fatal("out of memory");
	const argv_buf = std.heap.wasm_allocator.alloc(u8, buf_size) catch fatal("out of memory");
	if (wasi.args_get(argv.ptr, argv_buf.ptr) != .SUCCESS) fatal("cannot read the command-line arguments");
	if (argc > 0) program_name = std.mem.span(argv[0]);
	initEnviron();
	initPreopens();
	cwd = if (getenv("PWD")) |pwd| (if (pwd.len > 0 and pwd[0] == '/') pwd else "/") else "/";
	const Args = abi.RocList(abi.OsStr);
	const args = Args.allocate(if (argc > 0) argc - 1 else 0, &host);
	const items: []abi.OsStr = @constCast(args.items());
	for (items, 1..) |*item, i| item.* = osStr(std.mem.span(argv[i]));
	const status = abi.roc_main(args);
	wasi.proc_exit(@bitCast(if (status == 0 and debug_or_expect) 1 else status));
}

/// Called by the generated stub of every hosted function this host does not
/// implement (see ./build); worded like the LuaJIT host's missing-function error.
export fn roc_wasi_unsupported(name: [*]const u8, len: usize) noreturn {
	_ = writeAll(2, "basic-cli's WASI host does not provide hosted function ");
	_ = writeAll(2, name[0..len]);
	_ = writeAll(2, "\n");
	wasi.proc_exit(1);
}

fn fatal(message: []const u8) noreturn {
	_ = writeAll(2, message);
	_ = writeAll(2, "\n");
	wasi.proc_exit(1);
}

// Values ---------------------------------------------------------------------

/// A tag union value of glue type T: zeroed, with `tag` and its payload at
/// offset 0 (the payload union, or the payload bytes on 32-bit targets).
fn make(comptime T: type, tag: @FieldType(T, "tag"), payload: anytype) T {
	var r: T = undefined;
	@memset(std.mem.asBytes(&r), 0);
	r.tag = tag;
	const P = @TypeOf(payload);
	if (@sizeOf(P) != 0) {
		const dst: *align(1) P = @ptrCast(&r.payload);
		dst.* = payload;
	}
	return r;
}
fn PayloadOf(comptime T: type, comptime name: []const u8) type {
	return @typeInfo(@TypeOf(@field(T, "payload_" ++ name))).@"fn".return_type.?;
}
fn ok(comptime T: type, payload: anytype) T {
	return make(T, .Ok, payload);
}
/// Err carrying an IOErr, either directly or inside a single-variant wrapper
/// such as [StdoutErr(IOErr)] (whichever the glue layout says).
fn errIo(comptime T: type, io: abi.IOErr) T {
	const E = PayloadOf(T, "err");
	if (E == abi.IOErr) return make(T, .Err, io);
	return make(T, .Err, make(E, @enumFromInt(0), io));
}
fn osStr(bytes: []const u8) abi.OsStr {
	return osVal(abi.OsStr, bytes);
}
/// An OS string or path value (any [UnixBytes(List(U8)), Utf8(Str), ...]
/// glue type) holding `bytes` as UnixBytes, as basic-cli's Unix host makes them.
fn osVal(comptime T: type, bytes: []const u8) T {
	return make(T, .UnixBytes, abi.RocListWith(u8, false).fromSlice(bytes, &host));
}

// Errors ---------------------------------------------------------------------

/// The Linux errno and strerror text for a WASI errno, so an `Other` IOErr
/// reads as basic-cli's native host reports it ("<text> (os error <n>)").
fn linuxErrno(e: wasi.errno_t) struct { n: u16, text: []const u8 } {
	return switch (e) {
		.PERM => .{ .n = 1, .text = "Operation not permitted" },
		.NOENT => .{ .n = 2, .text = "No such file or directory" },
		.INTR => .{ .n = 4, .text = "Interrupted system call" },
		.IO => .{ .n = 5, .text = "Input/output error" },
		.BADF => .{ .n = 9, .text = "Bad file descriptor" },
		.AGAIN => .{ .n = 11, .text = "Resource temporarily unavailable" },
		.NOMEM => .{ .n = 12, .text = "Cannot allocate memory" },
		.ACCES => .{ .n = 13, .text = "Permission denied" },
		.EXIST => .{ .n = 17, .text = "File exists" },
		.XDEV => .{ .n = 18, .text = "Invalid cross-device link" },
		.NOTDIR => .{ .n = 20, .text = "Not a directory" },
		.ISDIR => .{ .n = 21, .text = "Is a directory" },
		.INVAL => .{ .n = 22, .text = "Invalid argument" },
		.NOSPC => .{ .n = 28, .text = "No space left on device" },
		.SPIPE => .{ .n = 29, .text = "Illegal seek" },
		.ROFS => .{ .n = 30, .text = "Read-only file system" },
		.PIPE => .{ .n = 32, .text = "Broken pipe" },
		.NAMETOOLONG => .{ .n = 36, .text = "File name too long" },
		.NOSYS => .{ .n = 38, .text = "Function not implemented" },
		.NOTEMPTY => .{ .n = 39, .text = "Directory not empty" },
		.LOOP => .{ .n = 40, .text = "Too many levels of symbolic links" },
		.ILSEQ => .{ .n = 84, .text = "Invalid or incomplete multibyte or wide character" },
		.OPNOTSUPP => .{ .n = 95, .text = "Operation not supported" },
		.NOTCAPABLE => .{ .n = 13, .text = "Permission denied" },
		else => .{ .n = 5, .text = "Input/output error" },
	};
}
/// std::io::ErrorKind for the errno values IOErr names (Rust std's
/// decode_error_kind); everything else is Other with the OS error text.
fn ioErr(e: wasi.errno_t) abi.IOErr {
	return switch (e) {
		.PERM, .ACCES, .NOTCAPABLE => make(abi.IOErr, .PermissionDenied, {}),
		.NOENT => make(abi.IOErr, .NotFound, {}),
		.INTR => make(abi.IOErr, .Interrupted, {}),
		.NOMEM => make(abi.IOErr, .OutOfMemory, {}),
		.EXIST => make(abi.IOErr, .AlreadyExists, {}),
		.NOTDIR => make(abi.IOErr, .NotADirectory, {}),
		.ISDIR => make(abi.IOErr, .IsADirectory, {}),
		.PIPE => make(abi.IOErr, .BrokenPipe, {}),
		.NOSYS, .OPNOTSUPP => make(abi.IOErr, .Unsupported, {}),
		else => blk: {
			const l = linuxErrno(e);
			var buf: [96]u8 = undefined;
			const text = std.fmt.bufPrint(&buf, "{s} (os error {d})", .{ l.text, l.n }) catch l.text;
			break :blk make(abi.IOErr, .Other, abi.RocStr.fromSlice(text, &host));
		},
	};
}

// System calls ---------------------------------------------------------------

/// Write every byte, or return the error that stopped it.
fn writeAll(fd: wasi.fd_t, bytes: []const u8) ?wasi.errno_t {
	var rest = bytes;
	while (rest.len > 0) {
		const iov = [_]wasi.ciovec_t{.{ .base = rest.ptr, .len = rest.len }};
		var n: usize = 0;
		const e = wasi.fd_write(fd, &iov, 1, &n);
		if (e == .INTR) continue;
		if (e != .SUCCESS) return e;
		rest = rest[n..];
	}
	return null;
}
fn readSome(fd: wasi.fd_t, buf: []u8) error{Io}!usize {
	while (true) {
		const iov = [_]wasi.iovec_t{.{ .base = buf.ptr, .len = buf.len }};
		var n: usize = 0;
		const e = wasi.fd_read(fd, &iov, 1, &n);
		if (e == .INTR) continue;
		if (e != .SUCCESS) {
			last_errno = e;
			return error.Io;
		}
		return n;
	}
}
var last_errno: wasi.errno_t = .SUCCESS;

// Standard streams -----------------------------------------------------------

fn writeResult(comptime T: type, fd: wasi.fd_t, bytes: []const u8, newline: bool) T {
	const e = writeAll(fd, bytes) orelse (if (newline) writeAll(fd, "\n") else null);
	if (e) |errno| return errIo(T, ioErr(errno));
	return ok(T, {});
}
export fn hosted_stdout_line(s: abi.RocStr) callconv(.c) abi.HostStdout_lineResult {
	defer s.decref(&host);
	return writeResult(abi.HostStdout_lineResult, 1, s.asSlice(), true);
}
export fn hosted_stdout_write(s: abi.RocStr) callconv(.c) abi.HostStdout_lineResult {
	defer s.decref(&host);
	return writeResult(abi.HostStdout_lineResult, 1, s.asSlice(), false);
}
export fn hosted_stdout_write_bytes(l: abi.RocListWith(u8, false)) callconv(.c) abi.HostStdout_lineResult {
	defer l.decref(&host);
	return writeResult(abi.HostStdout_lineResult, 1, l.items(), false);
}
export fn hosted_stderr_line(s: abi.RocStr) callconv(.c) abi.HostStderr_lineResult {
	defer s.decref(&host);
	return writeResult(abi.HostStderr_lineResult, 2, s.asSlice(), true);
}
export fn hosted_stderr_write(s: abi.RocStr) callconv(.c) abi.HostStderr_lineResult {
	defer s.decref(&host);
	return writeResult(abi.HostStderr_lineResult, 2, s.asSlice(), false);
}
export fn hosted_stderr_write_bytes(l: abi.RocListWith(u8, false)) callconv(.c) abi.HostStderr_lineResult {
	defer l.decref(&host);
	return writeResult(abi.HostStderr_lineResult, 2, l.items(), false);
}

/// Bytes read from stdin and not yet returned (stdin_line reads ahead).
var stdin_buf: std.ArrayList(u8) = .empty;
const STDIN_CHUNK = 16384;

fn stdinFill() error{Io}!usize {
	stdin_buf.ensureUnusedCapacity(std.heap.wasm_allocator, STDIN_CHUNK) catch fatal("out of memory");
	const n = try readSome(0, stdin_buf.unusedCapacitySlice()[0..STDIN_CHUNK]);
	stdin_buf.items.len += n;
	return n;
}
fn stdinTake(n: usize) void {
	const rest = stdin_buf.items.len - n;
	std.mem.copyForwards(u8, stdin_buf.items[0..rest], stdin_buf.items[n..]);
	stdin_buf.items.len = rest;
}
/// Try(Str, [EndOfFile, StdinErr(IOErr)]): the next line without its "\n"
/// (and a "\r" before it); a final line without a newline is still a line.
export fn hosted_stdin_line() callconv(.c) abi.HostStdin_lineResult {
	const T = abi.HostStdin_lineResult;
	const E = PayloadOf(T, "err");
	var scanned: usize = 0;
	while (true) {
		if (std.mem.findScalarPos(u8, stdin_buf.items, scanned, '\n')) |i| {
			var line = stdin_buf.items[0..i];
			if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
			const s = abi.RocStr.fromSlice(line, &host);
			stdinTake(i + 1);
			return ok(T, s);
		}
		scanned = stdin_buf.items.len;
		const n = stdinFill() catch return make(T, .Err, make(E, .StdinErr, lastIoErr()));
		if (n == 0) {
			if (stdin_buf.items.len == 0) return make(T, .Err, make(E, .EndOfFile, {}));
			var line = stdin_buf.items;
			if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
			const s = abi.RocStr.fromSlice(line, &host);
			stdin_buf.items.len = 0;
			return ok(T, s);
		}
	}
}
/// Try(List(U8), [EndOfFile, StdinErr(IOErr)]): at most STDIN_CHUNK bytes.
export fn hosted_stdin_bytes() callconv(.c) abi.HostStdin_bytesResult {
	const T = abi.HostStdin_bytesResult;
	const E = PayloadOf(T, "err");
	if (stdin_buf.items.len == 0) {
		const n = stdinFill() catch return make(T, .Err, make(E, .StdinErr, lastIoErr()));
		if (n == 0) return make(T, .Err, make(E, .EndOfFile, {}));
	}
	const take = @min(stdin_buf.items.len, STDIN_CHUNK);
	const bytes = PayloadOf(T, "ok").fromSlice(stdin_buf.items[0..take], &host);
	stdinTake(take);
	return ok(T, bytes);
}
/// Try(List(U8), [StdinErr(IOErr)]): everything left on stdin.
export fn hosted_stdin_read_to_end() callconv(.c) abi.HostStdin_read_to_endResult {
	const T = abi.HostStdin_read_to_endResult;
	while (true) {
		const n = stdinFill() catch return errIo(T, lastIoErr());
		if (n == 0) break;
	}
	const bytes = PayloadOf(T, "ok").fromSlice(stdin_buf.items, &host);
	stdin_buf.items.len = 0;
	return ok(T, bytes);
}

// Environment ----------------------------------------------------------------

/// Try(OsStr, [ProgramNameUnavailable]): argv[0] as the runtime passed it.
export fn hosted_env_program_name() callconv(.c) abi.HostEnv_program_nameResult {
	return ok(abi.HostEnv_program_nameResult, osStr(program_name));
}

// Time, randomness, sleep ------------------------------------------------------

/// Try(U128, [ClockBeforeEpoch]): nanoseconds since the Unix epoch.
export fn hosted_utc_now() callconv(.c) abi.HostUtc_nowResult {
	var ns: wasi.timestamp_t = 0;
	_ = wasi.clock_time_get(.REALTIME, 1, &ns);
	return ok(abi.HostUtc_nowResult, @as(u128, ns));
}
/// Nanoseconds since the first call (Instant::elapsed from a lazy origin).
var monotonic_origin: ?u64 = null;
export fn hosted_monotonic_now() callconv(.c) u64 {
	var ns: wasi.timestamp_t = 0;
	_ = wasi.clock_time_get(.MONOTONIC, 1, &ns);
	if (monotonic_origin == null) monotonic_origin = ns;
	return ns - monotonic_origin.?;
}
fn randomResult(comptime T: type, comptime V: type) T {
	var v: V = 0;
	const e = wasi.random_get(@ptrCast(&v), @sizeOf(V));
	if (e != .SUCCESS) return errIo(T, ioErr(e));
	return ok(T, v);
}
export fn hosted_random_seed_u32() callconv(.c) abi.HostRandom_seed_u32Result {
	return randomResult(abi.HostRandom_seed_u32Result, u32);
}
export fn hosted_random_seed_u64() callconv(.c) abi.HostRandom_seed_u64Result {
	return randomResult(abi.HostRandom_seed_u64Result, u64);
}
/// Blocks for `ms` milliseconds (poll_oneoff on a relative monotonic clock).
export fn hosted_sleep_millis(ms: u64) callconv(.c) void {
	const sub = wasi.subscription_t{
		.userdata = 0,
		.u = .{ .tag = .CLOCK, .u = .{ .clock = .{ .id = .MONOTONIC, .timeout = ms * std.time.ns_per_ms, .precision = 0, .flags = 0 } } },
	};
	var event: wasi.event_t = undefined;
	var n: usize = 0;
	_ = wasi.poll_oneoff(&sub, &event, 1, &n);
}

// POSIX over WASI -------------------------------------------------------------
// WASI has no working directory and reaches files only through preopened
// directories. Paths are made absolute against `cwd` (initialized from $PWD,
// which the runtime passes with the environment) and opened relative to the
// preopen with the longest matching prefix (`wasmtime run --dir=/` gives one
// for the whole filesystem). ".." is resolved lexically.

var cwd: []const u8 = "/";
var environ: []const []const u8 = &.{};
const Preopen = struct { fd: wasi.fd_t, path: []const u8 };
var preopens: std.ArrayList(Preopen) = .empty;
const gpa = std.heap.wasm_allocator;

fn initEnviron() void {
	var count: usize = 0;
	var size: usize = 0;
	if (wasi.environ_sizes_get(&count, &size) != .SUCCESS) return;
	const ptrs = gpa.alloc([*:0]u8, count) catch fatal("out of memory");
	const buf = gpa.alloc(u8, size) catch fatal("out of memory");
	if (wasi.environ_get(ptrs.ptr, buf.ptr) != .SUCCESS) return;
	const entries = gpa.alloc([]const u8, count) catch fatal("out of memory");
	for (ptrs, entries) |p, *e| e.* = std.mem.span(p);
	environ = entries;
}
fn getenv(name: []const u8) ?[]const u8 {
	for (environ) |entry| {
		if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
	}
	return null;
}
fn initPreopens() void {
	var fd: wasi.fd_t = 3;
	while (true) : (fd += 1) {
		var prestat: wasi.prestat_t = undefined;
		if (wasi.fd_prestat_get(fd, &prestat) != .SUCCESS) break;
		const name = gpa.alloc(u8, prestat.u.dir.pr_name_len) catch fatal("out of memory");
		if (wasi.fd_prestat_dir_name(fd, name.ptr, name.len) != .SUCCESS) continue;
		// A preopen named "." or relative stands for the working directory.
		const path = if (name.len > 0 and name[0] == '/') name else (std.fs.path.resolvePosix(gpa, &.{ "/", name }) catch fatal("out of memory"));
		preopens.append(gpa, .{ .fd = fd, .path = path }) catch fatal("out of memory");
	}
}

/// A system call's failure, its errno kept in `last_errno`.
const Sys = error{Sys};
fn fail(e: wasi.errno_t) Sys {
	last_errno = e;
	last_invalid = null;
	return error.Sys;
}
/// A failure Rust's std reports with its own message (io::Error::new(Other or
/// InvalidInput, ...)), an Other IOErr carrying that text.
var last_invalid: ?[]const u8 = null;
fn invalid(message: []const u8) Sys {
	last_errno = .INVAL;
	last_invalid = message;
	return error.Sys;
}
/// The IOErr for the last failure.
fn lastIoErr() abi.IOErr {
	if (last_invalid) |m| {
		last_invalid = null;
		return make(abi.IOErr, .Other, abi.RocStr.fromSlice(m, &host));
	}
	return ioErr(last_errno);
}
fn sys(e: wasi.errno_t) Sys!void {
	if (e != .SUCCESS) return fail(e);
}

/// The absolute, lexically normalized form of `path`.
fn absolutePath(a: std.mem.Allocator, path: []const u8) Sys![]const u8 {
	if (path.len == 0) return fail(.NOENT);
	return std.fs.path.resolvePosix(a, &.{ cwd, path }) catch fail(.NOMEM);
}
/// The preopened directory holding `path` and the path relative to it.
const Target = struct { fd: wasi.fd_t, rel: []const u8 };
fn resolve(a: std.mem.Allocator, path: []const u8) Sys!Target {
	const abs = try absolutePath(a, path);
	var best: ?Preopen = null;
	for (preopens.items) |p| {
		const inside = std.mem.eql(u8, p.path, "/") or (std.mem.startsWith(u8, abs, p.path) and (abs.len == p.path.len or abs[p.path.len] == '/'));
		if (inside and (best == null or p.path.len > best.?.path.len)) best = p;
	}
	const p = best orelse return fail(.NOTCAPABLE);
	var rel = abs[@min(abs.len, p.path.len)..];
	while (rel.len > 0 and rel[0] == '/') rel = rel[1..];
	return .{ .fd = p.fd, .rel = if (rel.len == 0) "." else rel };
}
fn statPath(a: std.mem.Allocator, path: []const u8, follow: bool) Sys!wasi.filestat_t {
	const t = try resolve(a, path);
	var st: wasi.filestat_t = undefined;
	try sys(wasi.path_filestat_get(t.fd, .{ .SYMLINK_FOLLOW = follow }, t.rel.ptr, t.rel.len, &st));
	return st;
}
/// Every right WASI defines (a runtime rejects undefined bits); inherited
/// rights, so files opened in a directory get what their operation needs.
const all_rights: wasi.rights_t = blk: {
	var r: wasi.rights_t = .{};
	for (@typeInfo(wasi.rights_t).@"struct".fields) |field| {
		if (field.type == bool) @field(r, field.name) = true;
	}
	break :blk r;
};
fn openPath(a: std.mem.Allocator, path: []const u8, oflags: wasi.oflags_t, rights: wasi.rights_t) Sys!wasi.fd_t {
	const t = try resolve(a, path);
	var fd: wasi.fd_t = undefined;
	try sys(wasi.path_open(t.fd, .{ .SYMLINK_FOLLOW = true }, t.rel.ptr, t.rel.len, oflags, rights, all_rights, .{}, &fd));
	return fd;
}
fn readFd(a: std.mem.Allocator, fd: wasi.fd_t) Sys![]u8 {
	var out: std.ArrayList(u8) = .empty;
	while (true) {
		out.ensureUnusedCapacity(a, 65536) catch return fail(.NOMEM);
		const n = readSome(fd, out.unusedCapacitySlice()) catch return error.Sys;
		if (n == 0) return out.items;
		out.items.len += n;
	}
}
/// fs::read.
fn readFile(a: std.mem.Allocator, path: []const u8) Sys![]u8 {
	const fd = try openPath(a, path, .{}, .{ .FD_READ = true, .FD_SEEK = true, .FD_FILESTAT_GET = true });
	defer _ = wasi.fd_close(fd);
	var st: wasi.filestat_t = undefined;
	try sys(wasi.fd_filestat_get(fd, &st));
	if (st.filetype == .DIRECTORY) return fail(.ISDIR);
	return readFd(a, fd);
}
/// fs::write: created or truncated.
fn writeFile(a: std.mem.Allocator, path: []const u8, bytes: []const u8) Sys!void {
	const fd = try openPath(a, path, .{ .CREAT = true, .TRUNC = true }, .{ .FD_WRITE = true, .FD_SEEK = true });
	defer _ = wasi.fd_close(fd);
	if (writeAll(fd, bytes)) |e| return fail(e);
}
fn mkdirPath(a: std.mem.Allocator, path: []const u8) Sys!void {
	const t = try resolve(a, path);
	try sys(wasi.path_create_directory(t.fd, t.rel.ptr, t.rel.len));
}
fn rmdirPath(a: std.mem.Allocator, path: []const u8) Sys!void {
	const t = try resolve(a, path);
	try sys(wasi.path_remove_directory(t.fd, t.rel.ptr, t.rel.len));
}
fn unlinkPath(a: std.mem.Allocator, path: []const u8) Sys!void {
	const t = try resolve(a, path);
	try sys(wasi.path_unlink_file(t.fd, t.rel.ptr, t.rel.len));
}
fn readlinkPath(a: std.mem.Allocator, path: []const u8) Sys![]u8 {
	const t = try resolve(a, path);
	var buf = a.alloc(u8, 4096) catch return fail(.NOMEM);
	var n: usize = 0;
	try sys(wasi.path_readlink(t.fd, t.rel.ptr, t.rel.len, buf.ptr, buf.len, &n));
	return buf[0..n];
}
/// fs::read_dir: entry paths joined to `dir`, in the order the runtime lists them.
fn readDir(a: std.mem.Allocator, dir: []const u8) Sys![]const []const u8 {
	const fd = try openPath(a, dir, .{ .DIRECTORY = true }, .{ .FD_READDIR = true, .FD_FILESTAT_GET = true });
	defer _ = wasi.fd_close(fd);
	var entries: std.ArrayList([]const u8) = .empty;
	var buf = a.alloc(u8, 65536) catch return fail(.NOMEM);
	var cookie: wasi.dircookie_t = 0;
	while (true) {
		var used: usize = 0;
		try sys(wasi.fd_readdir(fd, buf.ptr, buf.len, cookie, &used));
		var off: usize = 0;
		var progressed = false;
		while (off + @sizeOf(wasi.dirent_t) <= used) {
			const ent: *align(1) const wasi.dirent_t = @ptrCast(buf[off..].ptr);
			const name_start = off + @sizeOf(wasi.dirent_t);
			if (name_start + ent.namlen > used) break; // truncated entry: read again from its cookie
			const name = buf[name_start .. name_start + ent.namlen];
			if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, ".."))
				entries.append(a, join(a, dir, name)) catch return fail(.NOMEM);
			cookie = ent.next;
			off = name_start + ent.namlen;
			progressed = true;
		}
		if (used < buf.len or !progressed) return entries.items;
	}
}

/// Path::join and Path::parent for byte paths.
fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) []const u8 {
	if (dir.len == 0) return name;
	if (dir[dir.len - 1] == '/') return std.mem.concat(a, u8, &.{ dir, name }) catch fatal("out of memory");
	return std.mem.concat(a, u8, &.{ dir, "/", name }) catch fatal("out of memory");
}
fn parent(path: []const u8) ?[]const u8 {
	const trimmed = std.mem.trimEnd(u8, path, "/");
	if (trimmed.len == 0) return null; // "/" has no parent
	const cut = std.mem.findScalarLast(u8, trimmed, '/') orelse return "";
	if (cut == 0) return "/";
	return std.mem.trimEnd(u8, trimmed[0..cut], "/");
}
const Kind = enum { dir, file, other, sym_link };
fn kindOf(st: wasi.filestat_t) Kind {
	return switch (st.filetype) {
		.DIRECTORY => .dir,
		.REGULAR_FILE => .file,
		.SYMBOLIC_LINK => .sym_link,
		else => .other,
	};
}
fn isDir(a: std.mem.Allocator, path: []const u8) bool {
	const st = statPath(a, path, true) catch return false;
	return st.filetype == .DIRECTORY;
}
/// DirBuilder::create_dir_all.
fn createDirAll(a: std.mem.Allocator, path: []const u8) Sys!void {
	if (path.len == 0) return;
	mkdirPath(a, path) catch {
		if (last_errno != .NOENT) {
			if (isDir(a, path)) return;
			return error.Sys;
		}
		const up = parent(path) orelse return fail(.IO);
		try createDirAll(a, up);
		mkdirPath(a, path) catch {
			if (isDir(a, path)) return;
			return error.Sys;
		};
	};
}
/// fs::remove_dir_all: a symlink is removed itself; directories are emptied
/// depth first without following links.
fn removeDirAll(a: std.mem.Allocator, path: []const u8) Sys!void {
	const st = try statPath(a, path, false);
	if (kindOf(st) == .sym_link) return unlinkPath(a, path);
	try removeTree(a, path);
}
fn removeTree(a: std.mem.Allocator, dir: []const u8) Sys!void {
	for (try readDir(a, dir)) |child| {
		const st = try statPath(a, child, false);
		if (kindOf(st) == .dir) try removeTree(a, child) else try unlinkPath(a, child);
	}
	try rmdirPath(a, dir);
}

/// The bytes of a path or OS string argument (decode_path); WindowsU16s is
/// Unsupported on Unix. The argument is released.
fn fromNative(a: std.mem.Allocator, v: anytype) Sys![]const u8 {
	defer v.decref(&host);
	return switch (v.tag) {
		.UnixBytes => a.dupe(u8, v.payload_unix_bytes().items()) catch fail(.NOMEM),
		.Utf8 => a.dupe(u8, v.payload_utf8().asSlice()) catch fail(.NOMEM),
		.WindowsU16s => fail(.OPNOTSUPP),
	};
}
fn arena() std.heap.ArenaAllocator {
	return std.heap.ArenaAllocator.init(gpa);
}

// Environment (batch 2) --------------------------------------------------------

/// Try(OsStr, [EnvErr(IOErr), VarNotFound(OsStr)]).
export fn hosted_env_var(name: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostEnv_varResult {
	const T = abi.HostEnv_varResult;
	const E = PayloadOf(T, "err");
	var ar = arena();
	defer ar.deinit();
	const key = fromNative(ar.allocator(), name) catch return make(T, .Err, make(E, .EnvErr, lastIoErr()));
	if (key.len == 0 or std.mem.findAny(u8, key, "=\x00") != null)
		return make(T, .Err, make(E, .EnvErr, make(abi.IOErr, .Other, abi.RocStr.fromSlice("environment variable names cannot be empty or contain nul bytes or '='", &host))));
	const value = getenv(key) orelse return make(T, .Err, make(E, .VarNotFound, osVal(abi.UnixBytesOrUtf8OrWindowsU16s, key)));
	return ok(T, osVal(abi.UnixBytesOrUtf8OrWindowsU16s, value));
}
/// Try(Path, [CwdUnavailable]).
export fn hosted_env_cwd() callconv(.c) abi.HostEnv_cwdResult {
	return ok(abi.HostEnv_cwdResult, osVal(abi.UnixBytesOrUtf8OrWindowsU16s, cwd));
}
/// Try({}, IOErr): the new directory must exist.
export fn hosted_env_set_cwd(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostEnv_set_cwdResult {
	const T = abi.HostEnv_set_cwdResult;
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const p = fromNative(a, path) catch return errIo(T, lastIoErr());
	const st = statPath(a, p, true) catch return errIo(T, lastIoErr());
	if (st.filetype != .DIRECTORY) return errIo(T, ioErr(.NOTDIR));
	const abs = absolutePath(a, p) catch return errIo(T, lastIoErr());
	cwd = gpa.dupe(u8, abs) catch fatal("out of memory");
	return ok(T, {});
}
/// Try(Path, [ExePathUnavailable]): a WASI module has no executable path.
export fn hosted_env_exe_path() callconv(.c) abi.HostEnv_exe_pathResult {
	return make(abi.HostEnv_exe_pathResult, .Err, {});
}
/// std::env::temp_dir: $TMPDIR, else /tmp.
export fn hosted_env_temp_dir() callconv(.c) abi.UnixBytesOrUtf8OrWindowsU16s {
	return osVal(abi.UnixBytesOrUtf8OrWindowsU16s, getenv("TMPDIR") orelse "/tmp");
}
/// What Rust's std::env::consts report for wasm32-wasi: OTHER for both.
export fn hosted_env_platform() callconv(.c) abi.__AnonStruct_bca0d23b5d625934 {
	const R = abi.__AnonStruct_bca0d23b5d625934;
	return .{
		.arch = make(@FieldType(R, "arch"), .OTHER, abi.RocStr.fromSlice("wasm32", &host)),
		.os = make(@FieldType(R, "os"), .OTHER, abi.RocStr.fromSlice("wasi", &host)),
	};
}
/// List((OsStr, OsStr)) in environ order.
export fn hosted_env_dict() callconv(.c) abi.RocList(abi.__AnonStruct_69eee2ff6c448fed) {
	const Pair = abi.__AnonStruct_69eee2ff6c448fed;
	var count: usize = 0;
	for (environ) |entry| {
		if (std.mem.findScalar(u8, entry, '=')) |i| {
			if (i > 0) count += 1;
		}
	}
	const list = abi.RocList(Pair).allocate(count, &host);
	const items: []Pair = @constCast(list.items());
	var k: usize = 0;
	for (environ) |entry| {
		const i = std.mem.findScalar(u8, entry, '=') orelse continue;
		if (i == 0) continue;
		items[k] = .{ ._0 = osVal(abi.UnixBytesOrUtf8OrWindowsU16s, entry[0..i]), ._1 = osVal(abi.UnixBytesOrUtf8OrWindowsU16s, entry[i + 1 ..]) };
		k += 1;
	}
	return list;
}

// Locale -------------------------------------------------------------------------
// sys_locale's order (LANGUAGE's list, then LC_ALL, LC_MESSAGES, LANG), each
// cut at '.' or '@' with '_' as '-', then basic-cli's normalize_locale: C/POSIX
// and malformed BCP 47 tags dropped, duplicates (ignoring case) dropped.
fn localeIsValid(locale: []const u8) bool {
	var subtags: std.ArrayList([]const u8) = .empty;
	defer subtags.deinit(gpa);
	var it = std.mem.splitScalar(u8, locale, '-');
	while (it.next()) |s| subtags.append(gpa, s) catch return false;
	const language = subtags.items[0];
	if (language.len == 0) return false;
	for (subtags.items) |s| {
		if (s.len == 0 or s.len > 8) return false;
		for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
	}
	const special = language.len == 1 and (std.ascii.toLower(language[0]) == 'x' or std.ascii.toLower(language[0]) == 'i');
	if (!special) {
		if (language.len < 2 or language.len > 8) return false;
		for (language) |c| if (!std.ascii.isAlphabetic(c)) return false;
	}
	if (special and subtags.items.len == 1) return false;
	for (subtags.items[1..], 2..) |s, index| {
		if (s.len == 1 and index == subtags.items.len) return false;
		if (s.len == 1 and std.ascii.toLower(s[0]) == 'x') return index < subtags.items.len;
	}
	return true;
}
fn locales(a: std.mem.Allocator) []const []const u8 {
	var raw: std.ArrayList([]const u8) = .empty;
	const add = struct {
		fn f(al: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) void {
			const end = std.mem.findAny(u8, value, ".@") orelse value.len;
			const locale = al.dupe(u8, value[0..end]) catch return;
			std.mem.replaceScalar(u8, locale, '_', '-');
			for (list.items) |existing| if (std.mem.eql(u8, existing, locale)) return;
			list.append(al, locale) catch {};
		}
	}.f;
	if (getenv("LANGUAGE")) |language| {
		if (language.len > 0) {
			var it = std.mem.splitScalar(u8, language, ':');
			while (it.next()) |part| add(a, &raw, part);
		}
	}
	for ([_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
		if (getenv(name)) |value| if (value.len > 0) add(a, &raw, value);
	}
	var out: std.ArrayList([]const u8) = .empty;
	for (raw.items) |locale| {
		const trimmed = std.mem.trim(u8, locale, " \t\n\r");
		const end = std.mem.findAny(u8, trimmed, ".@") orelse trimmed.len;
		const base = trimmed[0..end];
		if (std.ascii.eqlIgnoreCase(base, "C") or std.ascii.eqlIgnoreCase(base, "POSIX")) continue;
		const normalized = a.dupe(u8, base) catch continue;
		std.mem.replaceScalar(u8, normalized, '_', '-');
		if (!localeIsValid(normalized)) continue;
		var seen = false;
		for (out.items) |existing| if (std.ascii.eqlIgnoreCase(existing, normalized)) {
			seen = true;
		};
		if (!seen) out.append(a, normalized) catch {};
	}
	return out.items;
}
export fn hosted_locale_all() callconv(.c) abi.RocList(abi.RocStr) {
	var ar = arena();
	defer ar.deinit();
	const all = locales(ar.allocator());
	const list = abi.RocList(abi.RocStr).allocate(all.len, &host);
	for (@constCast(list.items()), all) |*item, l| item.* = abi.RocStr.fromSlice(l, &host);
	return list;
}
/// Try(Str, [NotAvailable]).
export fn hosted_locale_get() callconv(.c) abi.HostLocale_getResult {
	var ar = arena();
	defer ar.deinit();
	const all = locales(ar.allocator());
	if (all.len == 0) return make(abi.HostLocale_getResult, .Err, {});
	return ok(abi.HostLocale_getResult, abi.RocStr.fromSlice(all[0], &host));
}

// Paths ------------------------------------------------------------------------

/// Try([Dir, File, Other, SymLink], IOErr), from symlink_metadata.
export fn hosted_path_type(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostPath_typeResult {
	const T = abi.HostPath_typeResult;
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const p = fromNative(a, path) catch return errIo(T, lastIoErr());
	const st = statPath(a, p, false) catch return errIo(T, lastIoErr());
	return ok(T, @as(PayloadOf(T, "ok"), switch (kindOf(st)) {
		.dir => .dir,
		.file => .file,
		.other => .other,
		.sym_link => .sym_link,
	}));
}
/// std::path::absolute on Unix: the working directory joined to a relative
/// path, components normalized except "..", a leading "//" (not "///") and a
/// trailing "/" kept, symlinks not resolved.
fn absolute(a: std.mem.Allocator, path: []const u8) Sys![]const u8 {
	if (path.len == 0) return invalid("cannot make an empty path absolute");
	var stripped = path;
	if (std.mem.eql(u8, path, ".")) stripped = "" else if (std.mem.startsWith(u8, path, "./")) stripped = std.mem.trimStart(u8, path[1..], "/");
	var out: std.ArrayList(u8) = .empty;
	if (path[0] == '/') {
		if (std.mem.startsWith(u8, path, "//") and !std.mem.startsWith(u8, path, "///")) out.appendSlice(a, "//") catch return fail(.NOMEM);
	} else {
		out.appendSlice(a, cwd) catch return fail(.NOMEM);
	}
	var it = std.mem.tokenizeScalar(u8, stripped, '/');
	while (it.next()) |part| {
		if (std.mem.eql(u8, part, ".")) continue;
		if (out.items.len == 0 or out.items[out.items.len - 1] != '/') out.append(a, '/') catch return fail(.NOMEM);
		out.appendSlice(a, part) catch return fail(.NOMEM);
	}
	if (out.items.len == 0) out.append(a, '/') catch return fail(.NOMEM);
	if (path[path.len - 1] == '/' and out.items[out.items.len - 1] != '/') out.append(a, '/') catch return fail(.NOMEM);
	return out.items;
}
/// fs::canonicalize (realpath): absolute, every symlink resolved, and the
/// path must exist.
fn canonicalize(a: std.mem.Allocator, path: []const u8) Sys![]const u8 {
	const MAX_LINKS = 40;
	if (path.len == 0) return fail(.NOENT);
	var pending: std.ArrayList([]const u8) = .empty; // components still to walk, last first
	const start = try absolutePath(a, if (path.len > 0 and path[0] == '/') path else join(a, cwd, path));
	var it = std.mem.tokenizeScalar(u8, start, '/');
	var parts: std.ArrayList([]const u8) = .empty;
	while (it.next()) |c| parts.append(a, c) catch return fail(.NOMEM);
	while (parts.pop()) |c| pending.append(a, c) catch return fail(.NOMEM);
	var resolved: []const u8 = "/";
	var links: usize = 0;
	while (pending.pop()) |c| {
		if (std.mem.eql(u8, c, ".")) continue;
		if (std.mem.eql(u8, c, "..")) {
			resolved = parent(resolved) orelse "/";
			if (resolved.len == 0) resolved = "/";
			continue;
		}
		const next = join(a, resolved, c);
		const st = try statPath(a, next, false);
		if (kindOf(st) != .sym_link) {
			resolved = next;
			continue;
		}
		links += 1;
		if (links > MAX_LINKS) return fail(.LOOP);
		const target = try readlinkPath(a, next);
		if (target.len > 0 and target[0] == '/') resolved = "/";
		var tp: std.ArrayList([]const u8) = .empty;
		var tit = std.mem.tokenizeScalar(u8, target, '/');
		while (tit.next()) |t| tp.append(a, t) catch return fail(.NOMEM);
		while (tp.pop()) |t| pending.append(a, t) catch return fail(.NOMEM);
	}
	_ = try statPath(a, resolved, true);
	return resolved;
}
fn pathResult(comptime T: type, path: anytype, comptime f: fn (std.mem.Allocator, []const u8) Sys![]const u8) T {
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const p = fromNative(a, path) catch return errIo(T, lastIoErr());
	const r = f(a, p) catch return errIo(T, lastIoErr());
	return ok(T, osVal(PayloadOf(T, "ok"), r));
}
export fn hosted_path_absolute(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostPath_absoluteResult {
	return pathResult(abi.HostPath_absoluteResult, path, absolute);
}
export fn hosted_path_canonicalize(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostPath_absoluteResult {
	return pathResult(abi.HostPath_absoluteResult, path, canonicalize);
}

// Files (whole-file operations and metadata) ------------------------------------

/// Run `f` on the decoded path, an Err(FileErr(IOErr)) on failure.
fn withPath(comptime T: type, path: abi.UnixBytesOrUtf8OrWindowsU16s, ctx: anytype, comptime f: anytype) T {
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const p = fromNative(a, path) catch return errIo(T, lastIoErr());
	return f(a, p, ctx) catch errIo(T, lastIoErr());
}
export fn hosted_file_read_bytes(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_read_bytesResult {
	const T = abi.HostFile_read_bytesResult;
	return withPath(T, path, {}, struct {
		fn f(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			return ok(T, PayloadOf(T, "ok").fromSlice(try readFile(a, p), &host));
		}
	}.f);
}
export fn hosted_file_read_utf8(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_read_utf8Result {
	const T = abi.HostFile_read_utf8Result;
	return withPath(T, path, {}, struct {
		fn f(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			const bytes = try readFile(a, p);
			if (!std.unicode.utf8ValidateSlice(bytes))
				return errIo(T, make(abi.IOErr, .Other, abi.RocStr.fromSlice("stream did not contain valid UTF-8", &host)));
			return ok(T, abi.RocStr.fromSlice(bytes, &host));
		}
	}.f);
}
export fn hosted_file_write_bytes(path: abi.UnixBytesOrUtf8OrWindowsU16s, l: abi.RocListWith(u8, false)) callconv(.c) abi.HostFile_deleteResult {
	const T = abi.HostFile_deleteResult;
	defer l.decref(&host);
	return withPath(T, path, l.items(), struct {
		fn f(a: std.mem.Allocator, p: []const u8, bytes: []const u8) Sys!T {
			try writeFile(a, p, bytes);
			return ok(T, {});
		}
	}.f);
}
export fn hosted_file_write_utf8(path: abi.UnixBytesOrUtf8OrWindowsU16s, s: abi.RocStr) callconv(.c) abi.HostFile_deleteResult {
	const T = abi.HostFile_deleteResult;
	defer s.decref(&host);
	return withPath(T, path, s.asSlice(), struct {
		fn f(a: std.mem.Allocator, p: []const u8, bytes: []const u8) Sys!T {
			try writeFile(a, p, bytes);
			return ok(T, {});
		}
	}.f);
}
export fn hosted_file_delete(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_deleteResult {
	const T = abi.HostFile_deleteResult;
	return withPath(T, path, {}, struct {
		fn f(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			try unlinkPath(a, p);
			return ok(T, {});
		}
	}.f);
}
fn twoPaths(comptime T: type, x: abi.UnixBytesOrUtf8OrWindowsU16s, y: abi.UnixBytesOrUtf8OrWindowsU16s, comptime op: anytype) T {
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const px = fromNative(a, x) catch {
		y.decref(&host);
		return errIo(T, lastIoErr());
	};
	const py = fromNative(a, y) catch return errIo(T, lastIoErr());
	const tx = resolve(a, px) catch return errIo(T, lastIoErr());
	const ty = resolve(a, py) catch return errIo(T, lastIoErr());
	const e = op(tx, ty);
	if (e != .SUCCESS) return errIo(T, ioErr(e));
	return ok(T, {});
}
export fn hosted_file_rename(x: abi.UnixBytesOrUtf8OrWindowsU16s, y: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_deleteResult {
	return twoPaths(abi.HostFile_deleteResult, x, y, struct {
		fn f(s: Target, d: Target) wasi.errno_t {
			return wasi.path_rename(s.fd, s.rel.ptr, s.rel.len, d.fd, d.rel.ptr, d.rel.len);
		}
	}.f);
}
export fn hosted_file_hard_link(x: abi.UnixBytesOrUtf8OrWindowsU16s, y: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_deleteResult {
	return twoPaths(abi.HostFile_deleteResult, x, y, struct {
		fn f(s: Target, d: Target) wasi.errno_t {
			return wasi.path_link(s.fd, .{}, s.rel.ptr, s.rel.len, d.fd, d.rel.ptr, d.rel.len);
		}
	}.f);
}
/// Metadata (fs::metadata follows symlinks).
fn withStat(comptime T: type, path: abi.UnixBytesOrUtf8OrWindowsU16s, comptime f: fn (wasi.filestat_t) T) T {
	return withPath(T, path, {}, struct {
		fn g(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			return f(try statPath(a, p, true));
		}
	}.g);
}
export fn hosted_file_size_in_bytes(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_size_in_bytesResult {
	const T = abi.HostFile_size_in_bytesResult;
	return withStat(T, path, struct {
		fn f(st: wasi.filestat_t) T {
			return ok(T, @as(u64, st.size));
		}
	}.f);
}
export fn hosted_file_time_accessed(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_time_accessedResult {
	const T = abi.HostFile_time_accessedResult;
	return withStat(T, path, struct {
		fn f(st: wasi.filestat_t) T {
			return ok(T, @as(u128, st.atim));
		}
	}.f);
}
export fn hosted_file_time_modified(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_time_accessedResult {
	const T = abi.HostFile_time_accessedResult;
	return withStat(T, path, struct {
		fn f(st: wasi.filestat_t) T {
			return ok(T, @as(u128, st.mtim));
		}
	}.f);
}
/// Metadata::created: WASI records no birth time, so this is Unsupported (as
/// native basic-cli reports on filesystems without one).
export fn hosted_file_time_created(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_time_accessedResult {
	const T = abi.HostFile_time_accessedResult;
	return withStat(T, path, struct {
		fn f(_: wasi.filestat_t) T {
			return errIo(T, ioErr(.NOSYS));
		}
	}.f);
}
/// WASI exposes no permission bits: readable and writable mean the file opens
/// for reading or writing; executable cannot be known (Unsupported).
fn openable(comptime T: type, path: abi.UnixBytesOrUtf8OrWindowsU16s, comptime rights: wasi.rights_t) T {
	return withPath(T, path, {}, struct {
		fn f(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			_ = try statPath(a, p, true);
			const fd = openPath(a, p, .{}, rights) catch return ok(T, false);
			_ = wasi.fd_close(fd);
			return ok(T, true);
		}
	}.f);
}
export fn hosted_file_is_readable(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_is_executableResult {
	return openable(abi.HostFile_is_executableResult, path, .{ .FD_READ = true });
}
export fn hosted_file_is_writable(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_is_executableResult {
	return openable(abi.HostFile_is_executableResult, path, .{ .FD_WRITE = true });
}
export fn hosted_file_is_executable(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostFile_is_executableResult {
	const T = abi.HostFile_is_executableResult;
	return withStat(T, path, struct {
		fn f(_: wasi.filestat_t) T {
			return errIo(T, ioErr(.NOSYS));
		}
	}.f);
}

// Directories ---------------------------------------------------------------------

fn dirOp(comptime T: type, path: abi.UnixBytesOrUtf8OrWindowsU16s, comptime op: fn (std.mem.Allocator, []const u8) Sys!void) T {
	return withPath(T, path, {}, struct {
		fn f(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			try op(a, p);
			return ok(T, {});
		}
	}.f);
}
export fn hosted_dir_create(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostDir_createResult {
	return dirOp(abi.HostDir_createResult, path, mkdirPath);
}
export fn hosted_dir_create_all(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostDir_createResult {
	return dirOp(abi.HostDir_createResult, path, createDirAll);
}
export fn hosted_dir_delete_empty(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostDir_createResult {
	return dirOp(abi.HostDir_createResult, path, rmdirPath);
}
export fn hosted_dir_delete_all(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostDir_createResult {
	return dirOp(abi.HostDir_createResult, path, removeDirAll);
}
export fn hosted_dir_list(path: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostDir_listResult {
	const T = abi.HostDir_listResult;
	return withPath(T, path, {}, struct {
		fn f(a: std.mem.Allocator, p: []const u8, _: void) Sys!T {
			const entries = try readDir(a, p);
			const L = PayloadOf(T, "ok");
			const list = L.allocate(entries.len, &host);
			const Item = @typeInfo(@TypeOf(L.items)).@"fn".return_type.?;
			const Elem = @typeInfo(Item).pointer.child;
			for (@constCast(list.items()), entries) |*item, e| item.* = osVal(Elem, e);
			return ok(T, list);
		}
	}.f);
}

// Temporary directories -------------------------------------------------------------

const ALPHANUMERIC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const TEMP_RANDOM_CHARS = 6;
/// tempfile's Builder::tempdir_in: a relative parent is joined to the working
/// directory; the name is the prefix and six random alphanumeric characters,
/// retried while it already exists.
fn createTempDir(a: std.mem.Allocator, dir_in: []const u8, prefix: []const u8) (Sys || error{InvalidPrefix})![]const u8 {
	if (std.mem.findAny(u8, prefix, "/\\:\x00") != null or std.mem.eql(u8, prefix, ".") or std.mem.eql(u8, prefix, ".."))
		return error.InvalidPrefix;
	const dir = if (dir_in.len > 0 and dir_in[0] == '/') dir_in else join(a, cwd, dir_in);
	while (true) {
		var random: [TEMP_RANDOM_CHARS]u8 = undefined;
		try sys(wasi.random_get(&random, random.len));
		var name: [TEMP_RANDOM_CHARS]u8 = undefined;
		for (random, &name) |r, *c| c.* = ALPHANUMERIC[r % ALPHANUMERIC.len];
		const path = join(a, dir, std.mem.concat(a, u8, &.{ prefix, &name }) catch return fail(.NOMEM));
		mkdirPath(a, path) catch {
			if (last_errno == .EXIST) continue;
			return error.Sys;
		};
		return path;
	}
}
/// Try(Path, IOErr).
export fn hosted_env_create_temp_dir(dir: abi.UnixBytesOrUtf8OrWindowsU16s, prefix: abi.RocStr) callconv(.c) abi.HostPath_absoluteResult {
	const T = abi.HostPath_absoluteResult;
	defer prefix.decref(&host);
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const d = fromNative(a, dir) catch return errIo(T, lastIoErr());
	const path = createTempDir(a, d, prefix.asSlice()) catch |e| switch (e) {
		error.InvalidPrefix => return errIo(T, make(abi.IOErr, .Other, abi.RocStr.fromSlice("temporary directory prefix must be a filename component", &host))),
		error.Sys => return errIo(T, lastIoErr()),
	};
	return ok(T, osVal(PayloadOf(T, "ok"), path));
}

// File readers ------------------------------------------------------------------
// A FileReader is a Box(U64) naming an entry here: BufReader<File> over a WASI
// fd. Each reader operation consumes one reference to the box (released after
// the operation, as basic-cli's resources.rs does); freeing the box's
// allocation closes the file (hostDealloc).

const Reader = struct { fd: wasi.fd_t, cap: usize, buf: std.ArrayList(u8), pos: usize };
var readers: std.AutoHashMapUnmanaged(u64, Reader) = .empty;
var reader_boxes: std.AutoHashMapUnmanaged(usize, u64) = .empty;
var next_reader: u64 = 1;
const READER_DEFAULT_CAPACITY = 8192;
/// Bytes between a boxed U64's allocation and its value (allocateBox's header).
const BOX_U64_HEADER = @max(@sizeOf(usize), @alignOf(u64));

fn closeReader(id: u64) void {
	if (readers.fetchRemove(id)) |entry| {
		_ = wasi.fd_close(entry.value.fd);
		var buf = entry.value.buf;
		buf.deinit(gpa);
	}
}
fn readerOf(handle: *u64) *Reader {
	return readers.getPtr(handle.*) orelse fatal("basic-cli WASI host: unknown file reader");
}
fn releaseHandle(handle: *u64) void {
	abi.decrefBox(@ptrCast(handle), &host);
}
fn buffered(r: *Reader) []const u8 {
	return r.buf.items[r.pos..];
}
/// BufReader::fill_buf: refill when everything buffered was consumed.
fn readerFill(r: *Reader) Sys!void {
	if (r.pos < r.buf.items.len) return;
	r.buf.clearRetainingCapacity();
	r.pos = 0;
	r.buf.ensureTotalCapacity(gpa, r.cap) catch return fail(.NOMEM);
	const n = readSome(r.fd, r.buf.allocatedSlice()[0..r.cap]) catch return error.Sys;
	r.buf.items.len = n;
}
/// BufReader::read: buffered bytes first; an empty buffer and a request at
/// least as large as it reads straight from the file.
fn readerRead(a: std.mem.Allocator, r: *Reader, count: usize) Sys![]const u8 {
	if (r.pos >= r.buf.items.len and count >= r.cap) {
		const out = a.alloc(u8, count) catch return fail(.NOMEM);
		const n = readSome(r.fd, out) catch return error.Sys;
		return out[0..n];
	}
	try readerFill(r);
	const chunk = buffered(r)[0..@min(count, buffered(r).len)];
	r.pos += chunk.len;
	return chunk;
}

export fn hosted_file_open_reader(path: abi.UnixBytesOrUtf8OrWindowsU16s, capacity: u64) callconv(.c) abi.HostFile_open_readerResult {
	const T = abi.HostFile_open_readerResult;
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const p = fromNative(a, path) catch return errIo(T, lastIoErr());
	const fd = openPath(a, p, .{}, .{ .FD_READ = true, .FD_SEEK = true, .FD_TELL = true, .FD_FILESTAT_GET = true }) catch return errIo(T, lastIoErr());
	const id = next_reader;
	next_reader += 1;
	readers.put(gpa, id, .{ .fd = fd, .cap = if (capacity == 0) READER_DEFAULT_CAPACITY else @intCast(capacity), .buf = .empty, .pos = 0 }) catch fatal("out of memory");
	const box: *u64 = @ptrCast(@alignCast(abi.allocateBox(@sizeOf(u64), @alignOf(u64), false, &host)));
	box.* = id;
	reader_boxes.put(gpa, @intFromPtr(box) - BOX_U64_HEADER, id) catch fatal("out of memory");
	return ok(T, box);
}
/// BufRead::read_until(b'\n'), the newline included.
export fn hosted_file_read_line(handle: *u64) callconv(.c) abi.HostFile_read_bytesResult {
	const T = abi.HostFile_read_bytesResult;
	defer releaseHandle(handle);
	const r = readerOf(handle);
	var line: std.ArrayList(u8) = .empty;
	defer line.deinit(gpa);
	while (true) {
		readerFill(r) catch return errIo(T, lastIoErr());
		const avail = buffered(r);
		if (avail.len == 0) break;
		const stop = if (std.mem.findScalar(u8, avail, '\n')) |i| i + 1 else avail.len;
		line.appendSlice(gpa, avail[0..stop]) catch fatal("out of memory");
		r.pos += stop;
		if (avail[stop - 1] == '\n') break;
	}
	return ok(T, PayloadOf(T, "ok").fromSlice(line.items, &host));
}
export fn hosted_file_read_up_to(handle: *u64, count: u64) callconv(.c) abi.HostFile_read_bytesResult {
	const T = abi.HostFile_read_bytesResult;
	defer releaseHandle(handle);
	var ar = arena();
	defer ar.deinit();
	if (count == 0) return ok(T, PayloadOf(T, "ok").empty());
	const bytes = readerRead(ar.allocator(), readerOf(handle), @intCast(count)) catch return errIo(T, lastIoErr());
	return ok(T, PayloadOf(T, "ok").fromSlice(bytes, &host));
}
/// Try(List(U8), [FileErr(IOErr), FileUnexpectedEOF]).
export fn hosted_file_read_exactly(handle: *u64, count: u64) callconv(.c) abi.HostFile_read_exactlyResult {
	const T = abi.HostFile_read_exactlyResult;
	const E = PayloadOf(T, "err");
	defer releaseHandle(handle);
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const r = readerOf(handle);
	var out: std.ArrayList(u8) = .empty;
	while (out.items.len < count) {
		const bytes = readerRead(a, r, @intCast(count - out.items.len)) catch return make(T, .Err, make(E, .FileErr, lastIoErr()));
		if (bytes.len == 0) return make(T, .Err, make(E, .FileUnexpectedEOF, {}));
		out.appendSlice(a, bytes) catch fatal("out of memory");
	}
	return ok(T, PayloadOf(T, "ok").fromSlice(out.items, &host));
}
/// Seek::stream_position: the file offset less what is still buffered.
export fn hosted_file_reader_position(handle: *u64) callconv(.c) abi.HostFile_size_in_bytesResult {
	const T = abi.HostFile_size_in_bytesResult;
	defer releaseHandle(handle);
	const r = readerOf(handle);
	var at: wasi.filesize_t = 0;
	const e = wasi.fd_seek(r.fd, 0, .CUR, &at);
	if (e != .SUCCESS) return errIo(T, ioErr(e));
	return ok(T, @as(u64, at - buffered(r).len));
}
/// [Current(I64), End(I64), Start(U64)]: BufReader::seek discards the
/// buffer; Current counts from the logical position.
export fn hosted_file_reader_seek(handle: *u64, from: abi.CurrentOrEndOrStart) callconv(.c) abi.HostFile_size_in_bytesResult {
	const T = abi.HostFile_size_in_bytesResult;
	defer releaseHandle(handle);
	const r = readerOf(handle);
	const raw: *align(1) const i64 = @ptrCast(&from.payload);
	var offset: i64 = raw.*;
	const whence: wasi.whence_t = switch (from.tag) {
		.Current => .CUR,
		.End => .END,
		.Start => .SET,
	};
	if (whence == .CUR) offset -= @intCast(buffered(r).len);
	var at: wasi.filesize_t = 0;
	const e = wasi.fd_seek(r.fd, offset, whence, &at);
	r.buf.clearRetainingCapacity();
	r.pos = 0;
	if (e != .SUCCESS) return errIo(T, ioErr(e));
	return ok(T, @as(u64, at));
}

// Copies (basic-cli's src/filesystem.rs) -------------------------------------------
// Permissions are not copied: WASI has no chmod.

const CopyFailure = PayloadOf(abi.HostPath_copyResult, "err");
const CopyError = union(enum) { sys: wasi.errno_t, invalid: []const u8 };
fn copyIoErr(e: CopyError) abi.IOErr {
	return switch (e) {
		.sys => |errno| ioErr(errno),
		.invalid => |m| make(abi.IOErr, .Other, abi.RocStr.fromSlice(m, &host)),
	};
}
fn copyFailure(operation: []const u8, source: []const u8, destination: []const u8, e: CopyError) abi.HostPath_copyResult {
	return make(abi.HostPath_copyResult, .Err, CopyFailure{
		.destination = osVal(abi.UnixBytesOrUtf8OrWindowsU16s, destination),
		.@"error" = copyIoErr(e),
		.operation = abi.RocStr.fromSlice(operation, &host),
		.source = osVal(abi.UnixBytesOrUtf8OrWindowsU16s, source),
	});
}
const copy_ok = ok(abi.HostPath_copyResult, {});
fn lastErr() CopyError {
	if (last_invalid) |m| {
		last_invalid = null;
		return .{ .invalid = m };
	}
	return .{ .sys = last_errno };
}
/// Path::starts_with, component by component.
fn startsWithPath(path: []const u8, base: []const u8) bool {
	var a = std.mem.tokenizeScalar(u8, path, '/');
	var b = std.mem.tokenizeScalar(u8, base, '/');
	if ((path.len > 0 and path[0] == '/') != (base.len > 0 and base[0] == '/')) return false;
	while (b.next()) |pb| {
		const pa = a.next() orelse return false;
		if (!std.mem.eql(u8, pa, pb)) return false;
	}
	return true;
}
/// prospective_canonical: canonicalize the existing ancestors, links
/// included, without requiring the leaf to exist.
fn prospectiveCanonical(a: std.mem.Allocator, path: []const u8) Sys![]const u8 {
	if (canonicalize(a, path)) |real| return real else |_| {}
	if (last_errno != .NOENT) return error.Sys;
	const abs = try absolute(a, path);
	var resolved: []const u8 = "";
	var it = std.mem.tokenizeScalar(u8, abs, '/');
	resolved = "/";
	while (it.next()) |part| {
		if (std.mem.eql(u8, part, "..")) {
			resolved = parent(resolved) orelse resolved;
			if (resolved.len == 0) resolved = "/";
		} else if (!std.mem.eql(u8, part, ".")) {
			resolved = join(a, resolved, part);
			if (canonicalize(a, resolved)) |r| resolved = r else |_| {
				if (last_errno != .NOENT) return error.Sys;
			}
		}
	}
	return resolved;
}
/// fs::copy without permissions: the destination is created or truncated.
fn fsCopy(a: std.mem.Allocator, source: []const u8, destination: []const u8) Sys!void {
	const input = try openPath(a, source, .{}, .{ .FD_READ = true, .FD_SEEK = true });
	defer _ = wasi.fd_close(input);
	const output = try openPath(a, destination, .{ .CREAT = true, .TRUNC = true }, .{ .FD_WRITE = true, .FD_SEEK = true });
	defer _ = wasi.fd_close(output);
	var buf: [65536]u8 = undefined;
	while (true) {
		const n = readSome(input, &buf) catch return error.Sys;
		if (n == 0) return;
		if (writeAll(output, buf[0..n])) |e| return fail(e);
	}
}
fn copyFile(a: std.mem.Allocator, source: []const u8, destination: []const u8) abi.HostPath_copyResult {
	const e: CopyError = blk: {
		const st = statPath(a, source, true) catch break :blk lastErr();
		if (kindOf(st) != .file) break :blk .{ .invalid = "source is not a regular file" };
		if (statPath(a, destination, true)) |dst| {
			if (kindOf(dst) != .file) break :blk .{ .invalid = "destination is not a regular file" };
			if (dst.dev == st.dev and dst.ino == st.ino) break :blk .{ .invalid = "source and destination identify the same file" };
		} else |_| {
			if (last_errno != .NOENT) break :blk lastErr();
		}
		fsCopy(a, source, destination) catch break :blk lastErr();
		return copy_ok;
	};
	return copyFailure("copy_file", source, destination, e);
}
/// copy_tree: depth first in readdir order; links are recreated (preserve)
/// or followed, with a cycle check on the resolved ancestors.
fn copyTree(a: std.mem.Allocator, source: []const u8, destination: []const u8, preserve: bool, merge: bool, ancestors: *std.StringHashMapUnmanaged(void)) abi.HostPath_copyResult {
	const resolved = canonicalize(a, source) catch return copyFailure("resolve_source", source, destination, lastErr());
	const resolved_destination = prospectiveCanonical(a, destination) catch return copyFailure("resolve_destination", source, destination, lastErr());
	if (startsWithPath(resolved_destination, resolved)) return copyFailure("copy_dir", source, destination, .{ .invalid = "destination is inside source" });
	if (ancestors.contains(resolved)) return copyFailure("copy_dir", source, destination, .{ .invalid = "symbolic link cycle" });
	ancestors.put(a, resolved, {}) catch fatal("out of memory");
	defer _ = ancestors.remove(resolved);
	const st = statPath(a, source, true) catch return copyFailure("metadata", source, destination, lastErr());
	if (kindOf(st) != .dir) return copyFailure("copy_dir", source, destination, .{ .sys = .NOTDIR });
	if (parent(destination)) |up| {
		if (up.len > 0) createDirAll(a, up) catch return copyFailure("create_parent_dirs", source, destination, lastErr());
	}
	mkdirPath(a, destination) catch {
		if (!(merge and last_errno == .EXIST)) return copyFailure("create_dir", source, destination, lastErr());
		const dst = statPath(a, destination, false) catch return copyFailure("metadata", source, destination, lastErr());
		if (kindOf(dst) != .dir) return copyFailure("create_dir", source, destination, .{ .sys = .NOTDIR });
	};
	const entries = readDir(a, source) catch return copyFailure("read_dir", source, destination, lastErr());
	for (entries) |src| {
		const base = src[(std.mem.findScalarLast(u8, src, '/') orelse return copyFailure("read_dir", source, destination, .{ .sys = .INVAL })) + 1 ..];
		const dst = join(a, destination, base);
		const link = statPath(a, src, false) catch return copyFailure("metadata", src, dst, lastErr());
		if (kindOf(link) == .sym_link and preserve) {
			const target = readlinkPath(a, src) catch return copyFailure("copy_symlink", src, dst, lastErr());
			const t = resolve(a, dst) catch return copyFailure("copy_symlink", src, dst, lastErr());
			const e = wasi.path_symlink(target.ptr, target.len, t.fd, t.rel.ptr, t.rel.len);
			if (e != .SUCCESS) return copyFailure("copy_symlink", src, dst, .{ .sys = e });
		} else {
			const target = statPath(a, src, true) catch return copyFailure("metadata", src, dst, lastErr());
			const r = if (kindOf(target) == .dir) copyTree(a, src, dst, preserve, merge, ancestors) else copyFile(a, src, dst);
			if (r.tag == .Err) return r;
		}
	}
	return copy_ok;
}
fn copyDir(a: std.mem.Allocator, source: []const u8, destination: []const u8, preserve: bool, merge: bool) abi.HostPath_copyResult {
	const src = canonicalize(a, source) catch return copyFailure("resolve_source", source, destination, lastErr());
	const dst = prospectiveCanonical(a, destination) catch return copyFailure("resolve_destination", source, destination, lastErr());
	if (startsWithPath(dst, src) or startsWithPath(src, dst)) return copyFailure("copy_dir", source, destination, .{ .invalid = "source and destination trees overlap" });
	var ancestors: std.StringHashMapUnmanaged(void) = .empty;
	return copyTree(a, source, destination, preserve, merge, &ancestors);
}
/// Both paths of a copy, or a decode_path failure that hands the original
/// values back.
fn nativeBytes(v: abi.UnixBytesOrUtf8OrWindowsU16s) ?[]const u8 {
	return switch (v.tag) {
		.UnixBytes => v.payload_unix_bytes().items(),
		.Utf8 => v.payload_utf8().asSlice(),
		.WindowsU16s => null,
	};
}
fn copyPaths(source: abi.UnixBytesOrUtf8OrWindowsU16s, destination: abi.UnixBytesOrUtf8OrWindowsU16s, ctx: anytype, comptime f: anytype) abi.HostPath_copyResult {
	var ar = arena();
	defer ar.deinit();
	const a = ar.allocator();
	const s = nativeBytes(source);
	const d = nativeBytes(destination);
	if (s == null or d == null) return make(abi.HostPath_copyResult, .Err, CopyFailure{
		.destination = destination,
		.@"error" = make(abi.IOErr, .Unsupported, {}),
		.operation = abi.RocStr.fromSlice("decode_path", &host),
		.source = source,
	});
	const sp = a.dupe(u8, s.?) catch fatal("out of memory");
	const dp = a.dupe(u8, d.?) catch fatal("out of memory");
	source.decref(&host);
	destination.decref(&host);
	return f(a, sp, dp, ctx);
}
export fn hosted_path_copy(source: abi.UnixBytesOrUtf8OrWindowsU16s, destination: abi.UnixBytesOrUtf8OrWindowsU16s) callconv(.c) abi.HostPath_copyResult {
	return copyPaths(source, destination, {}, struct {
		fn f(a: std.mem.Allocator, s: []const u8, d: []const u8, _: void) abi.HostPath_copyResult {
			return copyFile(a, s, d);
		}
	}.f);
}
/// CopyOptions { destination : [Merge, RequireNew], symlinks : [Follow, Preserve] }.
export fn hosted_path_copy_dir(source: abi.UnixBytesOrUtf8OrWindowsU16s, destination: abi.UnixBytesOrUtf8OrWindowsU16s, options: abi.__AnonStruct_dee0b5b198beef56) callconv(.c) abi.HostPath_copyResult {
	return copyPaths(source, destination, options, struct {
		fn f(a: std.mem.Allocator, s: []const u8, d: []const u8, o: abi.__AnonStruct_dee0b5b198beef56) abi.HostPath_copyResult {
			return copyDir(a, s, d, o.symlinks == .preserve, o.destination == .merge);
		}
	}.f);
}
