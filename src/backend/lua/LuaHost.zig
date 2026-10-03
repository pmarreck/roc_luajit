//! Assembles a runnable LuaJIT program from a platform-mode emitter chunk and
//! the platform's LuaJIT host (`roc build --target=luajit`).
//!
//! A LuaJIT host is a Lua module returning `{ run = function(app, argv) }`. It
//! calls `app(hosted)` with its hosted functions keyed by hosted symbol, gets
//! back `{ entrypoints = { [provides symbol] = proc }, rt = rt }`, and plays the
//! native host's role: build the entrypoint's arguments, call it through
//! `rt.call_entry`, report crashes and choose the exit status. Hosted
//! functions follow the native ABI's ownership: they consume their arguments.

const std = @import("std");

/// Host for the default platform that headerless apps build against.
pub const default_host_source = @embedFile("hosts/default.lua");

/// File name a platform directory uses for its LuaJIT host.
pub const host_file_name = "host.lua";

/// One `.roc` file of a platform's root directory.
pub const PlatformSource = struct {
    name: []const u8,
    source: []const u8,
};

/// A LuaJIT host shipped with roc_luajit for a platform that cannot carry its
/// own `host.lua` (a downloaded package), found by `platformFingerprint`.
pub const BundledHost = struct {
    platform: []const u8,
    fingerprint: *const [64]u8,
    source: []const u8,
};

/// Hosts for downloaded platforms.
pub const bundled_hosts = [_]BundledHost{
    .{
        .platform = "basic-cli 0.23.0",
        .fingerprint = "2f522ef7eda831e4ae7caa56569c540fe0126e88feb5c37e70c367bc09ac87da",
        .source = @embedFile("hosts/basic_cli_0_23_0.lua"),
    },
};

/// Identify a platform by its `.roc` sources, which fix its hosted interface
/// wherever the package was loaded from (URL cache or a local copy): SHA-256
/// over the files sorted by name, each written as name length, name, source
/// length and source (lengths as little-endian u64, so bytes cannot move
/// between a name and a source unnoticed). `scratch` holds at least
/// `sources.len` entries.
pub fn platformFingerprint(sources: []const PlatformSource, scratch: []PlatformSource) [64]u8 {
    const sorted = scratch[0..sources.len];
    @memcpy(sorted, sources);
    std.mem.sort(PlatformSource, sorted, {}, struct {
        fn lessThan(_: void, a: PlatformSource, b: PlatformSource) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted) |file| {
        for ([_][]const u8{ file.name, file.source }) |part| {
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, part.len, .little);
            hasher.update(&len);
            hasher.update(part);
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// The bundled host for a platform fingerprint, if roc_luajit ships one.
pub fn bundledHost(fingerprint: []const u8) ?[]const u8 {
    for (bundled_hosts) |host| {
        if (std.mem.eql(u8, host.fingerprint, fingerprint)) return host.source;
    }
    return null;
}

/// Write the executable Lua program: the host wrapped around the app chunk,
/// run with the process arguments (`arg`, which excludes argv[0]).
pub fn writeProgram(out: *std.Io.Writer, app_chunk: []const u8, host_source: []const u8) std.Io.Writer.Error!void {
    try out.writeAll("#!/usr/bin/env luajit\n-- Roc program for LuaJIT 2.1, built by roc_luajit.\nlocal APP = function(...)\n");
    try out.writeAll(app_chunk);
    try out.writeAll("\nend\nlocal HOST = (function()\n");
    try out.writeAll(host_source);
    try out.writeAll("\nend)()\nHOST.run(APP, arg)\n");
}

test "writeProgram wraps the app chunk and runs the host" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try writeProgram(&buffer.writer, "return 1", "return { run = print }");
    try std.testing.expectEqualStrings(
        "#!/usr/bin/env luajit\n-- Roc program for LuaJIT 2.1, built by roc_luajit.\nlocal APP = function(...)\nreturn 1\nend\nlocal HOST = (function()\nreturn { run = print }\nend)()\nHOST.run(APP, arg)\n",
        buffer.written(),
    );
}

test "platformFingerprint ignores order and changes with names or contents" {
    const a = [_]PlatformSource{ .{ .name = "main.roc", .source = "platform" }, .{ .name = "Host.roc", .source = "hosted" } };
    const reordered = [_]PlatformSource{ a[1], a[0] };
    const renamed = [_]PlatformSource{ .{ .name = "main.roc", .source = "platform" }, .{ .name = "Hosts.roc", .source = "hosted" } };
    const edited = [_]PlatformSource{ .{ .name = "main.roc", .source = "platform" }, .{ .name = "Host.roc", .source = "hosted!" } };
    // Moving bytes between a name and its contents must not collide.
    const shifted = [_]PlatformSource{ .{ .name = "main.rocp", .source = "latform" }, .{ .name = "Host.roc", .source = "hosted" } };
    var scratch: [4]PlatformSource = undefined;
    const fp = platformFingerprint(&a, &scratch);
    try std.testing.expectEqualStrings(&fp, &platformFingerprint(&reordered, &scratch));
    try std.testing.expect(!std.mem.eql(u8, &fp, &platformFingerprint(&renamed, &scratch)));
    try std.testing.expect(!std.mem.eql(u8, &fp, &platformFingerprint(&edited, &scratch)));
    try std.testing.expect(!std.mem.eql(u8, &fp, &platformFingerprint(&shifted, &scratch)));
}

test "bundledHost finds hosts by fingerprint only" {
    for (bundled_hosts) |host| try std.testing.expectEqual(host.source.ptr, bundledHost(host.fingerprint).?.ptr);
    try std.testing.expectEqual(@as(?[]const u8, null), bundledHost("0" ** 64));
}
