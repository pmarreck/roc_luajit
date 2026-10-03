//! Differential harness for the experimental LuaJIT backend (roc_luajit).
//!
//! For each eval-corpus program the harness compiles once, then executes the
//! same ARC-complete LIR two independent ways:
//!
//!   - the oracle: the LIR interpreter, cross-checked against the corpus's
//!     static expected `Str.inspect` rendering;
//!   - the subject: `backend.lua` emits Lua source, which a separate `luajit`
//!     process runs. The emitter cannot reach the interpreter (a structural
//!     test forbids it), so agreement cannot come from running the oracle twice.
//!
//! Results must agree on the output bytes, or on the crash status and message.
//! Programs outside the emitter's subset are counted per stated reason, never
//! passed. The run fails on any divergence or Lua error, on zero passes, or
//! when unsupported cases exceed `max-unsupported=N`.
//!
//! Negative controls: `mutate=int-literals` perturbs every integer literal the
//! emitter writes and `mutate=dec-literals` every Dec literal; with
//! `expect-divergence` the run passes only if at least one case diverges and
//! none passes, proving the comparison bites.

const std = @import("std");
const eval = @import("eval");
const backend = @import("backend");
const collections = @import("collections");
const test_harness = @import("test_harness");
const build_options = @import("build_options");
const CoreCtx = @import("ctx").CoreCtx;

const helpers = eval.test_helpers;
const eval_tests = @import("eval_tests.zig");
const LuaEmitter = backend.lua;
const posix = std.posix;

const RunnerError = std.mem.Allocator.Error || test_harness.Timer.Error || test_harness.WorkerArgvError || std.fmt.ParseIntError || error{
    InvalidArgument,
    Diverged,
    LuaErrors,
    OracleErrors,
    NothingExecuted,
    TooManyUnsupported,
    ControlDidNotBite,
};

const Case = struct {
    name: []const u8,
    source: []const u8,
    source_kind: helpers.SourceKind = .expr,
    imports: []const helpers.ModuleSource = &.{},
    expected_inspect: ?[]const u8 = null,
};

const CaseStatus = enum {
    /// Oracle and LuaJIT agreed.
    pass,
    /// Oracle and LuaJIT disagreed.
    diverged,
    /// The emitter refused a construct (detail names it).
    unsupported,
    /// The generated Lua failed outside the Roc crash protocol, or luajit could not run.
    lua_error,
    /// The program did not compile in this harness configuration.
    compile_skip,
    /// The interpreter failed, or disagreed with the corpus's static expectation.
    oracle_error,
    /// The isolated child process died (compiler panic, signal, or timeout).
    child_failed,
};

const CaseResult = struct {
    status: CaseStatus,
    detail: ?[]u8 = null,
    timed_out: bool = false,
};

const Totals = struct {
    pass: usize = 0,
    diverged: usize = 0,
    unsupported: usize = 0,
    lua_error: usize = 0,
    compile_skip: usize = 0,
    oracle_error: usize = 0,
    child_failed: usize = 0,
};

var verbose_logging: bool = false;
var mutation: LuaEmitter.Mutation = .none;

fn logVerbose(comptime fmt: []const u8, args: anytype) void {
    if (verbose_logging) std.debug.print(fmt, args);
}

fn statusByte(status: CaseStatus) u8 {
    return switch (status) {
        .pass => 'P',
        .diverged => 'D',
        .unsupported => 'U',
        .lua_error => 'L',
        .compile_skip => 'C',
        .oracle_error => 'O',
        .child_failed => 'F',
    };
}

fn statusFromByte(byte: u8) ?CaseStatus {
    return switch (byte) {
        'P' => .pass,
        'D' => .diverged,
        'U' => .unsupported,
        'L' => .lua_error,
        'C' => .compile_skip,
        'O' => .oracle_error,
        'F' => .child_failed,
        else => null,
    };
}

fn runCaseForPool(io: std.Io, allocator: std.mem.Allocator, case: Case, timeout_ms: u64) CaseResult {
    _ = timeout_ms; // the pool's parent-side watchdog enforces the budget
    return runCase(allocator, io, case) catch |err| .{
        .status = .child_failed,
        .detail = std.fmt.allocPrint(allocator, "child error: {s}", .{@errorName(err)}) catch null,
    };
}

fn serializeCaseResult(fd: posix.fd_t, result: CaseResult) void {
    test_harness.writeAll(fd, &[_]u8{statusByte(result.status)});
    if (result.detail) |detail| test_harness.writeAll(fd, detail);
}

fn serializeCaseResultStreamed(fd: posix.fd_t, result: CaseResult) void {
    const detail_len = if (result.detail) |detail| detail.len else 0;
    test_harness.writeFrameHeader(fd, 1 + detail_len);
    serializeCaseResult(fd, result);
}

fn deserializeCaseResult(buf: []const u8, gpa: std.mem.Allocator) ?CaseResult {
    if (buf.len == 0) return null;
    const status = statusFromByte(buf[0]) orelse return null;
    const detail: ?[]u8 = if (buf.len > 1) gpa.dupe(u8, buf[1..]) catch null else null;
    return .{ .status = status, .detail = detail };
}

fn stabilizeCaseResult(gpa: std.mem.Allocator, result: CaseResult) CaseResult {
    return .{
        .status = result.status,
        .detail = if (result.detail) |detail| gpa.dupe(u8, detail) catch null else null,
        .timed_out = result.timed_out,
    };
}

fn getCaseName(case: Case) []const u8 {
    return case.name;
}

const Pool = test_harness.ProcessPool(Case, CaseResult, .{
    .runTest = &runCaseForPool,
    .serialize = &serializeCaseResult,
    .serializeStreamed = &serializeCaseResultStreamed,
    .deserialize = &deserializeCaseResult,
    .default_result = .{ .status = .child_failed },
    .timeout_result = .{ .status = .child_failed, .timed_out = true },
    .stabilizeResult = &stabilizeCaseResult,
    .getName = &getCaseName,
    .use_process_groups = true,
});

const UnsupportedEntry = struct {
    count: usize,
    example: []const u8,
};

/// Entry point for the LuaJIT differential harness.
pub fn main(init: std.process.Init) RunnerError!void {
    const io = init.io;

    var gpa_impl: std.heap.DebugAllocator(.{ .stack_trace_frames = build_options.debug_gpa_stack_trace_frames }) = .init;
    defer _ = build_options.debugGpaOk(gpa_impl.deinit());
    const gpa = gpa_impl.allocator();

    var args_arena = collections.SingleThreadArena.init(gpa);
    defer args_arena.deinit();
    const cli = try test_harness.parseStandardArgs(args_arena.allocator(), init.minimal.args);
    if (cli.help_requested) {
        printHelp();
        return;
    }
    verbose_logging = cli.verbose;

    var max_unsupported: ?usize = null;
    var expect_divergence = false;
    var max_cases: ?usize = null;
    for (cli.positional) |arg| {
        if (std.mem.eql(u8, arg, "mutate=int-literals")) {
            mutation = .int_literals;
        } else if (std.mem.eql(u8, arg, "mutate=dec-literals")) {
            mutation = .dec_literals;
        } else if (std.mem.eql(u8, arg, "expect-divergence")) {
            expect_divergence = true;
        } else if (std.mem.startsWith(u8, arg, "max-unsupported=")) {
            max_unsupported = try std.fmt.parseInt(usize, arg["max-unsupported=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "max-cases=")) {
            max_cases = try std.fmt.parseInt(usize, arg["max-cases=".len..], 10);
        } else {
            std.debug.print("unknown positional argument: {s}\n", .{arg});
            printHelp();
            return error.InvalidArgument;
        }
    }

    var run_list: std.ArrayList(Case) = .empty;
    defer run_list.deinit(gpa);
    for (eval_tests.tests) |tc| {
        if (tc.opt_in and cli.filters.len == 0) continue;
        const expected_inspect: ?[]const u8 = switch (tc.expected) {
            // Frontend-problem cases have nothing to execute.
            .problem, .problem_and_crash => continue,
            .inspect_str => |text| text,
            .allocations_at_most, .comptime_f32_bits, .comptime_f64_bits, .comptime_f32_list_bits, .comptime_f64_list_bits, .crash => null,
        };
        if (cli.filters.len > 0) {
            var matched = false;
            for (cli.filters) |pattern| {
                if (std.mem.find(u8, tc.name, pattern) != null or std.mem.find(u8, tc.source, pattern) != null) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }
        if (max_cases) |limit| if (run_list.items.len >= limit) break;
        try run_list.append(gpa, .{
            .name = tc.name,
            .source = tc.source,
            .source_kind = tc.source_kind,
            .imports = tc.imports,
            .expected_inspect = expected_inspect,
        });
    }

    if (Pool.runWorkerMode(io, cli, run_list.items, cli.timeout_ms)) return;

    var timer = try test_harness.Timer.start();
    const results = try gpa.alloc(CaseResult, run_list.items.len);
    defer gpa.free(results);
    @memset(results, .{ .status = .child_failed });
    const worker_argv_template = try test_harness.buildWorkerArgvTemplate(io, args_arena.allocator(), init.minimal.args);
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const job_limit = @max(cli.max_threads orelse @min(cpu_count, run_list.items.len), 1);
    Pool.run(io, run_list.items, results, job_limit, cli.timeout_ms, gpa, worker_argv_template);

    var totals: Totals = .{};
    var reasons: std.StringArrayHashMapUnmanaged(UnsupportedEntry) = .empty;
    defer {
        for (reasons.keys()) |key| gpa.free(key);
        reasons.deinit(gpa);
    }
    for (run_list.items, results) |case, result| {
        switch (result.status) {
            .pass => {
                totals.pass += 1;
                logVerbose("PASS        {s}  {s}\n", .{ case.name, result.detail orelse "" });
            },
            .diverged => {
                totals.diverged += 1;
                std.debug.print("DIVERGED    {s}\n{s}\n", .{ case.name, result.detail orelse "(no detail)" });
            },
            .lua_error => {
                totals.lua_error += 1;
                std.debug.print("LUA-ERROR   {s}\n{s}\n", .{ case.name, result.detail orelse "(no detail)" });
            },
            .oracle_error => {
                totals.oracle_error += 1;
                std.debug.print("ORACLE-ERR  {s}: {s}\n", .{ case.name, result.detail orelse "(no detail)" });
            },
            .compile_skip => {
                totals.compile_skip += 1;
                logVerbose("NO-COMPILE  {s}\n", .{case.name});
            },
            .child_failed => {
                totals.child_failed += 1;
                std.debug.print("CHILD-FAIL  {s}: {s}\n", .{ case.name, result.detail orelse if (result.timed_out) "timed out" else "child died" });
            },
            .unsupported => {
                totals.unsupported += 1;
                const reason = result.detail orelse "(unknown construct)";
                logVerbose("UNSUPPORTED {s}: {s}\n", .{ case.name, reason });
                const entry = try reasons.getOrPut(gpa, reason);
                if (entry.found_existing) {
                    entry.value_ptr.count += 1;
                } else {
                    entry.key_ptr.* = try gpa.dupe(u8, reason);
                    entry.value_ptr.* = .{ .count = 1, .example = case.name };
                }
            },
        }
        if (result.detail) |detail| gpa.free(detail);
    }

    const elapsed_ms = timer.read() / 1_000_000;
    std.debug.print(
        "\nluajit differential: {d} cases in {d} ms{s}\n" ++
            "  agreed:            {d}\n" ++
            "  diverged:          {d}\n" ++
            "  lua errors:        {d}\n" ++
            "  oracle errors:     {d}\n" ++
            "  unsupported:       {d}\n" ++
            "  did not compile:   {d}\n" ++
            "  child failures:    {d}\n",
        .{
            run_list.items.len,
            elapsed_ms,
            if (mutation != .none) " (negative control: mutated emitter)" else "",
            totals.pass,
            totals.diverged,
            totals.lua_error,
            totals.oracle_error,
            totals.unsupported,
            totals.compile_skip,
            totals.child_failed,
        },
    );
    if (reasons.count() > 0) {
        std.debug.print("\nunsupported constructs (stated coverage gaps):\n", .{});
        const Sorter = struct {
            entries: []const UnsupportedEntry,
            pub fn lessThan(self: @This(), a: usize, b: usize) bool {
                return self.entries[a].count > self.entries[b].count;
            }
        };
        reasons.sort(Sorter{ .entries = reasons.values() });
        for (reasons.keys(), reasons.values()) |reason, entry| {
            std.debug.print("  {d:>5}  {s}  (e.g. \"{s}\")\n", .{ entry.count, reason, entry.example });
        }
    }

    if (expect_divergence) {
        if (totals.diverged == 0 or totals.pass != 0) {
            std.debug.print("\nFAILED: negative control expected divergences and no passes\n", .{});
            return error.ControlDidNotBite;
        }
        std.debug.print("\nOK (negative control bit: {d} divergence(s))\n", .{totals.diverged});
        return;
    }
    if (totals.diverged > 0) return error.Diverged;
    if (totals.lua_error > 0) return error.LuaErrors;
    if (totals.oracle_error > 0 or totals.child_failed > 0) return error.OracleErrors;
    if (totals.pass == 0) {
        std.debug.print("\nFAILED: no case executed differentially\n", .{});
        return error.NothingExecuted;
    }
    if (max_unsupported) |limit| {
        if (totals.unsupported > limit) {
            std.debug.print("\nFAILED: {d} unsupported cases exceed the ratchet of {d}\n", .{ totals.unsupported, limit });
            return error.TooManyUnsupported;
        }
    }
    std.debug.print("\nOK\n", .{});
}

fn printHelp() void {
    std.debug.print(
        "luajit differential runner\n\n" ++
            "Compares the LIR interpreter (oracle) with Lua emitted by backend.lua\n" ++
            "and run in a separate luajit process (ROC_LUAJIT_BIN, default: luajit).\n\n" ++
            "Options:\n" ++
            "  --filter <substr>     only cases whose name/source matches (repeatable)\n" ++
            "  --threads <N>         max concurrent case processes\n" ++
            "  --timeout <ms>        per-case watchdog budget\n" ++
            "  --verbose             per-case logging, including the SHA-256 of emitted Lua\n" ++
            "  max-unsupported=N     fail when more than N cases are unsupported\n" ++
            "  max-cases=N           stop after N cases\n" ++
            "  mutate=int-literals   negative control: perturb emitted integer literals\n" ++
            "  mutate=dec-literals   negative control: perturb emitted Dec literals\n" ++
            "  expect-divergence     pass only if the run diverges (use with mutate=)\n",
        .{},
    );
}

fn runCase(gpa: std.mem.Allocator, io: std.Io, case: Case) std.mem.Allocator.Error!CaseResult {
    var compiled = helpers.compileInspectedProgram(gpa, io, case.source_kind, case.source, case.imports) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .status = .compile_skip },
    };
    defer compiled.deinit(gpa);
    const lowered = &compiled.lowered;

    var transcript = helpers.lirInterpreterTranscript(gpa, lowered) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .status = .oracle_error, .detail = try std.fmt.allocPrint(gpa, "interpreter: {s}", .{@errorName(err)}) },
    };
    defer transcript.deinit(gpa);

    if (case.expected_inspect) |expected| {
        const agrees = switch (transcript.outcome) {
            .output => |bytes| std.mem.eql(u8, bytes, expected),
            .aborted => false,
        };
        if (!agrees) return .{ .status = .oracle_error, .detail = try gpa.dupe(u8, "interpreter disagrees with the corpus expectation") };
    }

    const emitted = try LuaEmitter.emitProgram(gpa, .{
        .store = &lowered.view.store,
        .layouts = &lowered.view.layouts,
        .main_proc = lowered.mainProc(),
    }, .{ .mutation = mutation });
    defer emitted.deinit(gpa);
    const lua_source = switch (emitted) {
        .unsupported => |reason| return .{ .status = .unsupported, .detail = try gpa.dupe(u8, reason) },
        .lua => |source| source,
    };

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lua_source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const tmp_dir = if (std.c.getenv("TMPDIR")) |raw| std.mem.span(raw) else "/tmp";
    const path = try std.fmt.allocPrint(gpa, "{s}/roc-luajit-{d}-{s}.lua", .{ tmp_dir, std.c.getpid(), digest_hex[0..16] });
    defer gpa.free(path);
    const fs = CoreCtx.default(gpa, gpa, io);
    fs.writeFile(path, lua_source) catch |err| {
        return .{ .status = .lua_error, .detail = try std.fmt.allocPrint(gpa, "writing {s}: {s}", .{ path, @errorName(err) }) };
    };
    defer fs.deleteFile(path) catch {};

    const luajit = if (std.c.getenv("ROC_LUAJIT_BIN")) |raw| std.mem.span(raw) else "luajit";
    const run = std.process.run(gpa, io, .{ .argv = &.{ luajit, path } }) catch |err| {
        return .{ .status = .lua_error, .detail = try std.fmt.allocPrint(gpa, "spawning {s}: {s}", .{ luajit, @errorName(err) }) };
    };
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const exit_code: ?u8 = switch (run.term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => null,
    };

    const Lua = struct {
        const ok: u8 = 0;
        const crashed: u8 = 3;
    };
    switch (transcript.outcome) {
        .output => |expected| {
            if (exit_code == Lua.ok and std.mem.eql(u8, run.stdout, expected)) {
                return .{ .status = .pass, .detail = try gpa.dupe(u8, &digest_hex) };
            }
            if (exit_code != Lua.ok and exit_code != Lua.crashed) return luaError(gpa, run, &digest_hex);
            return .{ .status = .diverged, .detail = try std.fmt.allocPrint(
                gpa,
                "  oracle output: \"{s}\"\n  luajit exit {?d}, stdout \"{s}\", stderr \"{s}\"\n  lua sha256 {s}",
                .{ expected, exit_code, run.stdout, run.stderr, digest_hex },
            ) };
        },
        .aborted => |aborted| {
            if (aborted.kind != .crash) {
                return .{ .status = .unsupported, .detail = try std.fmt.allocPrint(gpa, "oracle abort kind {s}", .{@tagName(aborted.kind)}) };
            }
            const message = aborted.message orelse "";
            if (exit_code == Lua.crashed and std.mem.eql(u8, run.stderr, message)) {
                return .{ .status = .pass, .detail = try gpa.dupe(u8, &digest_hex) };
            }
            if (exit_code != Lua.ok and exit_code != Lua.crashed) return luaError(gpa, run, &digest_hex);
            return .{ .status = .diverged, .detail = try std.fmt.allocPrint(
                gpa,
                "  oracle crash: \"{s}\"\n  luajit exit {?d}, stdout \"{s}\", stderr \"{s}\"\n  lua sha256 {s}",
                .{ message, exit_code, run.stdout, run.stderr, digest_hex },
            ) };
        },
    }
}

fn luaError(gpa: std.mem.Allocator, run: std.process.RunResult, digest_hex: []const u8) std.mem.Allocator.Error!CaseResult {
    return .{ .status = .lua_error, .detail = try std.fmt.allocPrint(
        gpa,
        "  luajit {s}\n  stderr: {s}\n  lua sha256 {s}",
        .{ @tagName(run.term), run.stderr, digest_hex },
    ) };
}
