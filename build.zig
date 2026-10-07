const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const roc = b.dependency("roc", .{ .target = target, .optimize = optimize });
    const lua = b.addModule("lua", .{
        .root_source_file = b.path("src/backend/lua/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    inline for (.{ "lir", "layout", "base" }) |name| lua.addImport(name, roc.module(name));
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root.addImport("lua", lua);
    const default_app = b.createModule(.{ .root_source_file = roc.path("src/cli/default_app.zig"), .target = target, .optimize = optimize });
    inline for (.{ "base", "parse", "can", "reporting" }) |name| default_app.addImport(name, roc.module(name));
    root.addImport("default_app", default_app);
    root.addImport("echo_platform", roc.module("echo_platform"));
    inline for (.{ "compile", "eval", "lir", "check", "base", "ctx", "reporting", "roc_target", "build_options" }) |name| root.addImport(name, roc.module(name));
    const exe = b.addExecutable(.{ .name = "roc", .root_module = root });
    exe.stack_size = 64 * 1024 * 1024;
    b.installArtifact(exe);

    const build_cli = b.step("roc", "Build the standalone Roc-to-LuaJIT CLI");
    build_cli.dependOn(&b.addInstallArtifact(exe, .{}).step);
    const fx_specs = b.addInstallFile(roc.path("src/cli/test/fx_test_specs.zig"), "test-data/fx_test_specs.zig");
    const glue_source = b.addInstallFile(roc.path("src/glue/src/ZigGlue.roc"), "test-data/ZigGlue.roc");
    inline for (.{ fx_specs, glue_source }) |data| {
        build_cli.dependOn(&data.step);
        b.getInstallStep().dependOn(&data.step);
    }
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the standalone CLI").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = lua, .filters = &.{
        "Lua string literals escape every non-printable byte exactly",
        "every LowLevel op defaults to unsupported unless listed",
        "wide literals are eight 16-bit limbs, least significant first",
        "float literals are exact Lua numbers",
        "writeProgram wraps the app chunk and runs the host",
        "platformFingerprint ignores order and changes with names or contents",
        "bundledHost finds hosts by fingerprint only",
    } });
    const numeric = b.addExecutable(.{ .name = "luajit-numeric-vectors", .root_module = b.createModule(.{
        .root_source_file = b.path("src/backend/lua/test/numeric_vectors.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    numeric.root_module.addImport("builtins", roc.module("builtins"));
    numeric.root_module.addImport("ctx", roc.module("ctx"));
    const harness = b.createModule(.{ .root_source_file = roc.path("src/build/test_harness.zig"), .target = target, .optimize = optimize });
    harness.addImport("collections", roc.module("collections"));
    harness.addImport("build_options", roc.module("build_options"));
    const corpus = b.createModule(.{ .root_source_file = roc.path("src/eval/test/eval_tests.zig"), .target = target, .optimize = optimize });
    const upstream_modules = roc.builder.modules;
    var module_it = upstream_modules.iterator();
    while (module_it.next()) |entry| corpus.addImport(entry.key_ptr.*, entry.value_ptr.*);
    corpus.addImport("test_harness", harness);
    corpus.addImport("simd_test_sources", b.createModule(.{ .root_source_file = b.path("test/simd/eval_sources.zig") }));
    const differential = b.addExecutable(.{ .name = "luajit-differential-runner", .root_module = b.createModule(.{
        .root_source_file = b.path("src/testing/differential.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    differential.stack_size = 64 * 1024 * 1024;
    differential.root_module.addImport("lua", lua);
    inline for (.{ "eval", "collections", "build_options", "ctx" }) |name| differential.root_module.addImport(name, roc.module(name));
    differential.root_module.addImport("eval_tests", corpus);
    differential.root_module.addImport("test_harness", harness);
    const test_tools = b.step("build-test-luajit-differential", "Build downstream differential and numeric test tools");
    test_tools.dependOn(&b.addInstallArtifact(numeric, .{}).step);
    test_tools.dependOn(&b.addInstallArtifact(differential, .{}).step);
    const pinned_url = @import("build.zig.zon").dependencies.roc.url;
    const revision_separator = std.mem.indexOfScalar(u8, pinned_url, '#').?;
    const native_build = b.addSystemCommand(&.{"bash"});
    native_build.addFileArg(b.path("luajit_backend/scripts/build-native"));
    native_build.addArgs(&.{ b.graph.zig_exe, pinned_url["git+".len..revision_separator], pinned_url[revision_separator + 1 ..] });
    const native_output = native_build.addOutputDirectoryArg("native-roc");
    const native_install = b.addInstallFile(native_output.path(b, b.fmt("bin/roc{s}", .{target.result.exeFileExt()})), b.fmt("bin/roc-native{s}", .{target.result.exeFileExt()}));
    const native_step = b.step("native", "Build the pinned upstream CLI as the native test oracle");
    native_step.dependOn(&native_install.step);
    // Roc's distributed CLI resolves this SDK beside the executable.
    const darwin_sdk = b.addInstallDirectory(.{ .source_dir = roc.path("src/cli/darwin"), .install_dir = .bin, .install_subdir = "darwin" });
    native_step.dependOn(&darwin_sdk.step);
    const host_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
    const host_roc = b.dependency("roc", .{ .target = host_target, .optimize = .ReleaseFast });
    const host_module = b.createModule(.{
        .root_source_file = b.path("luajit_backend/platforms/lua/host.zig"),
        .target = host_target,
        .optimize = .ReleaseFast,
        .pic = true,
    });
    inline for (.{ "builtins", "host_alloc", "shim_io" }) |name| host_module.addImport(name, host_roc.module(name));
    const host_lib = b.addLibrary(.{ .name = "lua-platform-host", .linkage = .static, .root_module = host_module });
    b.step("lua-platform-host", "Build the Lua platform native host with upstream runtime modules").dependOn(&b.addInstallArtifact(host_lib, .{}).step);
    if (b.option([]const u8, "wasi-abi", "Generated WASI platform ABI source")) |abi_path| {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
        const wasm_roc = b.dependency("roc", .{ .target = wasm_target, .optimize = .ReleaseFast });
        const wasm_root = b.createModule(.{ .root_source_file = b.path("luajit_backend/platforms/wasi_basic_cli/host.zig"), .target = wasm_target, .optimize = .ReleaseFast, .pic = true });
        wasm_root.addImport("abi", b.createModule(.{ .root_source_file = .{ .cwd_relative = abi_path } }));
        wasm_root.addImport("shim_symbols", wasm_roc.module("shim_symbols"));
        const wasm_host = b.addObject(.{ .name = "wasi-host", .root_module = wasm_root });
        wasm_host.bundle_compiler_rt = true;
        b.step("wasi-platform-host", "Build the WASI host with upstream shim symbols").dependOn(&b.addInstallFile(wasm_host.getEmittedBin(), "wasi-host.wasm").step);
    }
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Test the Lua emitter and host assembly").dependOn(&run_tests.step);
}
