//! Standalone driver for the upstream Roc pipeline and downstream Lua backend.
const std = @import("std");
const compile = @import("compile");
const lir = @import("lir");
const check = @import("check");
const base = @import("base");
const reporting = @import("reporting");
const roc_target = @import("roc_target");
const lua = @import("lua");

/// Compile with the pinned Roc libraries and emit a self-contained Lua program.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2 or std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: roc build <app.roc> [--output=<file.lua>] [--target=luajit]\n       roc check <app.roc>\n", .{});
        return;
    }
    const command = args[1];
    if (!std.mem.eql(u8, command, "build") and !std.mem.eql(u8, command, "check")) return error.UnknownCommand;
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var replacements: compile.package_resolution.ReplaceDeps = .{};
    var strategy: base.SpecializationStrategy = .lss;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg[9..];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i == args.len) return error.MissingOutput;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--replace-dep")) {
            if (i + 2 >= args.len) return error.MissingReplacement;
            try replacements.append(.{ .old = args[i + 1], .new = args[i + 2] });
            i += 2;
        } else if (std.mem.eql(u8, arg, "--target=luajit") or std.mem.eql(u8, arg, "--no-cache")) {} else if (std.mem.eql(u8, arg, "--specialize=no")) {
            strategy = .boxy;
        } else if (std.mem.eql(u8, arg, "--specialize=yes")) {
            strategy = .lss;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else {
            if (input != null) return error.MultipleInputs;
            input = arg;
        }
    }
    const path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, input orelse return error.MissingInput, arena);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", arena);
    const target = roc_target.host_cpu.nativeTarget();
    var env = try compile.BuildEnv.init(init.gpa, .single_threaded, 1, target, cwd, init.io);
    defer env.deinit();
    env.resolution_config.replace_deps = replacements;
    env.compiler_version = @import("build_options").compiler_version;
    const config: compile.build.RuntimeLoweringConfig = .{ .target = .{
        .target_usize = base.target.TargetUsize.fromPtrBitWidth(target.ptrBitWidth()),
        .specialization_strategy = strategy,
        .inline_expects = .omit,
    } };
    if (std.mem.eql(u8, command, "build")) env.setRuntimeLowering(config);
    var diagnostics: std.Io.Writer.Allocating = .init(init.gpa);
    defer diagnostics.deinit();
    const default_app = @import("default_app");
    const original = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(256 * 1024 * 1024));
    var preparation = try default_app.stage(init.gpa, std.fs.path.dirname(path).?, original, if (std.mem.eql(u8, command, "check")) .checking else .execution, path);
    defer preparation.deinit(init.gpa);
    var temp_dir: ?[]const u8 = null;
    defer if (temp_dir) |dir| std.Io.Dir.cwd().deleteTree(init.io, dir) catch {};
    var compile_path: []const u8 = path;
    const default_host = switch (preparation) {
        .unmodified => false,
        .invalid => |reports| {
            const report_config = reporting.ReportingConfig.initColorTerminal();
            for (reports.items) |*report| try reporting.renderReportToTerminal(report, &diagnostics.writer, reporting.ColorUtils.getPaletteForConfig(report_config), report_config);
            std.debug.print("{s}", .{diagnostics.written()});
            return error.InvalidSource;
        },
        .staged => |staged| blk: {
            var nonce: [16]u8 = undefined;
            std.Io.random(init.io, &nonce);
            const temp_root = init.environ_map.get("TMPDIR") orelse "/tmp";
            temp_dir = try std.fs.path.join(arena, &.{ temp_root, try std.fmt.allocPrint(arena, "roc-luajit-{s}", .{std.fmt.bytesToHex(nonce, .lower)}) });
            const platform_dir = try std.fs.path.join(arena, &.{ temp_dir.?, default_app.platform_dir_name });
            try std.Io.Dir.cwd().createDirPath(init.io, platform_dir);
            compile_path = try std.fs.path.join(arena, &.{ temp_dir.?, std.fs.path.basename(path) });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = compile_path, .data = staged.synthetic_source });
            const echo = @import("echo_platform");
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(arena, &.{ platform_dir, "main.roc" }), .data = echo.build_platform_main_source });
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = try std.fs.path.join(arena, &.{ platform_dir, "Echo.roc" }), .data = echo.echo_module_source });
            env.setRootSourceDirOverride(std.fs.path.dirname(path).?);
            env.setSyntheticRootSourceMappingWithLineOffset(path, staged.original_source, staged.header_len, staged.header_lines);
            break :blk true;
        },
    };
    env.discoverDependencies(compile_path) catch |err| {
        _ = try env.renderDiagnostics(&diagnostics.writer, reporting.ReportingConfig.initColorTerminal());
        std.debug.print("{s}", .{diagnostics.written()});
        return err;
    };
    env.compileDiscovered() catch |err| {
        _ = try env.renderDiagnostics(&diagnostics.writer, reporting.ReportingConfig.initColorTerminal());
        std.debug.print("{s}", .{diagnostics.written()});
        return err;
    };
    const summary = try env.renderDiagnostics(&diagnostics.writer, reporting.ReportingConfig.initColorTerminal());
    if (diagnostics.written().len != 0) std.debug.print("{s}", .{diagnostics.written()});
    if (summary.errors != 0) return error.CheckFailed;
    if (std.mem.eql(u8, command, "check")) return;
    const root = env.executableRootCheckedArtifact();
    if (root.hasUnboundPlatformRequirements()) return error.UnboundPlatformRequirements;
    const imports = try env.collectImportedArtifactViews(arena, root);
    const relations = try env.collectRelationArtifactViews(arena, root);
    const requests = try lir.CheckedPipeline.selectPlatformEntrypointRoots(arena, root.root_requests.runtime_requests);
    // Runtime lowering was configured explicitly before checking; its session
    // owns completed compile-time facts. Never reconstruct them downstream.
    const session = env.runtimeProgramSession().?;
    var lowered = try session.takeRuntime(init.gpa, .{ .requests = requests }, config.target);
    defer lowered.deinit();
    const entries = try lowered.platformEntrypoints(arena);
    const names = try lowered.platformEntrypointNames(arena, root);
    const exports = try compile.static_data_exports.buildStaticData(init.gpa, .{
        .root = check.CheckedArtifact.loweringViewWithRelations(root, relations),
        .imports = imports,
    }, &lowered, target, .{});
    defer compile.static_data_exports.deinitStaticData(init.gpa, exports);
    const lua_entries = try arena.alloc(lua.emitter.Entrypoint, entries.len);
    for (entries, lua_entries) |entry, *destination| destination.* = .{ .name = names[entry.ordinal], .proc = entry.root_proc };
    if (lua_entries.len == 0) return error.NoEntrypoints;
    const emitted = try lua.emitter.emitProgram(init.gpa, .{
        .store = &lowered.lir_result.store,
        .layouts = &lowered.lir_result.layouts,
        .main_proc = lua_entries[0].proc,
        .entrypoints = lua_entries,
        .static_data = exports,
    }, .{});
    defer emitted.deinit(init.gpa);
    const chunk = switch (emitted) {
        .lua => |source| source,
        .unsupported => |reason| {
            std.debug.print("Unsupported LuaJIT construct: {s}\n", .{reason});
            return error.UnsupportedConstruct;
        },
    };
    const platform_path = env.getPlatformRootFile() orelse return error.NoPlatform;
    const host = if (default_host) lua.host.default_host_source else try platformHost(init, std.fs.path.dirname(platform_path).?);
    var program: std.Io.Writer.Allocating = .init(init.gpa);
    defer program.deinit();
    try lua.host.writeProgram(&program.writer, chunk, host);
    const output_path = output orelse try std.fmt.allocPrint(arena, "{s}.lua", .{std.fs.path.stem(path)});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = program.written(), .flags = .{ .permissions = .executable_file } });
}

fn platformHost(init: std.process.Init, path: []const u8) ![]const u8 {
    const arena = init.arena.allocator();
    var dir = try std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true });
    defer dir.close(init.io);
    const host = dir.readFileAlloc(init.io, lua.host.host_file_name, arena, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (host) |source| return source;
    var sources: std.ArrayList(lua.host.PlatformSource) = .empty;
    var it = dir.iterate();
    while (try it.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".roc")) continue;
        try sources.append(arena, .{ .name = try arena.dupe(u8, entry.name), .source = try dir.readFileAlloc(init.io, entry.name, arena, .limited(16 * 1024 * 1024)) });
    }
    const fingerprint = lua.host.platformFingerprint(sources.items, try arena.alloc(lua.host.PlatformSource, sources.items.len));
    return lua.host.bundledHost(&fingerprint) orelse {
        std.debug.print("Platform {s} needs host.lua (fingerprint {s})\n", .{ path, fingerprint });
        return error.NoPlatformHost;
    };
}
