//! Lua source emitter for ARC-complete LIR (experimental LuaJIT backend).
//!
//! Translates one program's reachable procedures into a single LuaJIT 2.1
//! source file (Lua 5.1 plus `goto`, `ffi`, `bit` and LL/ULL literals). The
//! emitter is pure: it reads the LIR store and committed layouts and returns
//! text. It never inspects ownership: every `incref`, `decref`,
//! `decref_if_initialized` and `free` statement becomes a call into the Lua
//! runtime's helper for the statement's value representation.
//!
//! Anything outside the implemented subset is refused with a named reason
//! (`Output.unsupported`), never approximated. See ARCHITECTURE.md §3-§5.

const std = @import("std");
const lir = @import("lir");
const layout = @import("layout");
const numeric_conversion = @import("base").numeric_conversion;

const LIR = lir.LIR;
const LirStore = lir.LirStore;
const GuardedList = LirStore.GuardedList;
const CheckedArithmetic = lir.CheckedArithmetic;
const LowLevel = LIR.LowLevel;
const Allocator = std.mem.Allocator;

/// The Lua runtime prepended to every emitted program.
pub const runtime_source = @embedFile("runtime.lua");
/// Exact limb arithmetic the runtime's 128-bit and Dec operations are built on.
pub const wide_source = @embedFile("wide.lua");
/// I128, U128 and Dec operations over `wide_source`, passed to the runtime.
pub const int128_source = @embedFile("int128.lua");
/// The List implementation (a port of builtins/list.zig), passed to the runtime.
pub const list_source = @embedFile("list.lua");
/// F32/F64 rounding, bit access and Roc's float formatting, passed to the runtime.
pub const float_source = @embedFile("float.lua");
/// Fluxsort (a port of builtins/sort.zig), passed to the List implementation.
pub const sort_source = @embedFile("sort.lua");
/// Integer, Dec and float parsers (ports of num.zig and decimal_parse.zig).
pub const numparse_source = @embedFile("numparse.lua");
/// F32/F64 transcendentals: ports of `src/builtins/float_math`.
pub const fmath_source = @embedFile("fmath.lua");
/// 128-bit integer SIMD: a port of `builtins/simd.zig` over an FFI union.
pub const simd_source = @embedFile("simd.lua");
/// SHA-256 and BLAKE3: ports of `builtins/crypto.zig` and its hashers.
pub const crypto_source = @embedFile("crypto.lua");

/// Parsing the prelude dominates a small program's startup, so the rarely
/// used modules are embedded as long strings and compiled on first use:
/// `LAZY(build)` is a table whose first missing-key read builds the module,
/// copies its fields in and drops its metatable, so later reads are plain
/// table reads.
const lazy_module_source =
    \\local function LAZY(build)
    \\    return setmetatable({}, { __index = function(t, k)
    \\        setmetatable(t, nil)
    \\        for name, v in pairs(build()) do rawset(t, name, v) end
    \\        return rawget(t, k)
    \\    end })
    \\end
    \\local function COMPILE(src, name) return (assert(loadstring(src, "=" .. name))()) end
    \\
;
/// Long brackets around a lazily compiled module's source, which must not
/// contain the closing one.
const lazy_open = "[==========[";
const lazy_close = "]==========]";
comptime {
    @setEvalBranchQuota(50_000_000);
    for ([_][]const u8{ sort_source, numparse_source, fmath_source, simd_source, crypto_source }) |src| {
        if (std.mem.find(u8, src, lazy_close) != null) @compileError("a lazily compiled prelude module contains " ++ lazy_close);
    }
}

/// LuaJIT allows 200 locals per function; keep headroom for the runtime's
/// own temporaries.
const max_frame_locals = 190;

/// LuaJIT gives each coroutine a fixed 65,500-slot stack (LUAI_MAXSTACK),
/// far below the native stack Roc recursion assumes. Every procedure adds its
/// frame estimate (declared locals plus `frame_slot_margin` for temporaries
/// and frame links) to `DEPTH` and subtracts it on return; past
/// `hop_depth_slots` the call continues on a fresh coroutine (`HOP`), whose
/// stack starts empty. Like the native stack, the total is bounded: past
/// `max_hops` nested hops (about 2.9M slots) the call raises LuaJIT's own
/// "stack overflow" error, which hosts report as native Roc's overflow.
const frame_slot_margin = 16;
const hop_depth_slots = 45000;
const max_hops = 64;
const stack_hop_source = std.fmt.comptimePrint(
    \\local DEPTH, HOPS = 0, 0
    \\local co_create, co_resume = coroutine.create, coroutine.resume
    \\local function HOP_DONE(saved, ok, ...)
    \\    DEPTH = saved
    \\    HOPS = HOPS - 1
    \\    if not ok then error((...), 0) end
    \\    return ...
    \\end
    \\local function HOP(f, ...)
    \\    if HOPS >= {d} then error("stack overflow", 0) end
    \\    local saved = DEPTH
    \\    DEPTH = 0
    \\    HOPS = HOPS + 1
    \\    return HOP_DONE(saved, co_resume(co_create(f), ...))
    \\end
    \\
, .{max_hops});

/// What the emitter reads. `main_proc` is the root whose returned `Str` the
/// program prints.
/// A platform entrypoint: the `provides` symbol and its root procedure.
pub const Entrypoint = struct {
    name: []const u8,
    proc: LIR.LirProcSpecId,
};

/// What the emitter reads: one lowered program's LIR store and layouts, the
/// root procedure (eval mode) or platform entrypoints, and its frozen static data.
pub const Input = struct {
    store: *const LirStore,
    layouts: *const layout.Store,
    main_proc: LIR.LirProcSpecId,
    /// Platform mode when non-empty: the program is a chunk taking the
    /// platform's hosted-function table (keyed by hosted symbol) and returning
    /// `{ entrypoints = { [name] = proc }, rt = rt }` instead of running
    /// `main_proc` (see LuaHost.zig).
    entrypoints: []const Entrypoint = &.{},
    /// Frozen static data (`static_data.buildStaticData`): the target-ABI bytes
    /// and relocations each `static_data` literal decodes from.
    static_data: []const lir.Program.StaticDataExport = &.{},
};

/// Test-only perturbations used by the differential runner's negative
/// control. They make correct programs produce wrong output on purpose.
pub const Mutation = enum {
    none,
    /// Add one to every integer literal.
    int_literals,
    /// Add one unit in the last place (10^-18) to every Dec literal.
    dec_literals,
};

/// Emission options; the default emits faithful code.
pub const Options = struct {
    mutation: Mutation = .none,
};

/// Emission result: Lua source, or the reason the program is outside the
/// implemented subset. Both slices are owned by the caller.
pub const Output = union(enum) {
    lua: []u8,
    unsupported: []u8,

    pub fn deinit(self: Output, gpa: Allocator) void {
        switch (self) {
            .lua, .unsupported => |bytes| gpa.free(bytes),
        }
    }
};

/// Emit a complete LuaJIT program that runs `input.main_proc` and writes its
/// `Str` result to stdout. Procedures are discovered from `main_proc` through
/// direct calls and emitted in ascending id order, so output is deterministic.
pub fn emitProgram(gpa: Allocator, input: Input, options: Options) Allocator.Error!Output {
    var emitter = Emitter{
        .gpa = gpa,
        .input = input,
        .options = options,
        .out = .init(gpa),
    };
    defer emitter.deinit();

    emitter.emitAll() catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        error.Unsupported => {
            const reason = emitter.unsupported_reason orelse "unsupported construct";
            return .{ .unsupported = try gpa.dupe(u8, reason) };
        },
    };
    return .{ .lua = try emitter.out.toOwnedSlice() };
}

const EmitError = Allocator.Error || std.Io.Writer.Error || error{Unsupported};

/// Node of a flattened aggregate's leaf shape (`Emitter.shapeOf`). Leaves of
/// a subtree are `leaf_count` consecutive leaf indices from `leaf_first` (for
/// a tag union, `leaf_first` is its discriminant, and every variant's payload
/// starts right after it, sharing leaves since one variant is live); children are
/// `child_count` consecutive `shape_children` entries from `child_first`
/// (struct fields by original index, tag variants by variant index, which is
/// the discriminant value the representation stores).
const ShapeKind = enum { leaf, zst, struct_, tag };
const ShapeNode = struct {
    kind: ShapeKind,
    layout: layout.Idx,
    leaf_first: u32 = 0,
    leaf_count: u32 = 0,
    child_first: u32 = 0,
    child_count: u32 = 0,
};

/// Leaves a flattened aggregate may take; larger values stay Lua tables.
const max_flat_leaves = 16;

/// Per procedure: each loop header's segment and the segments of its loop.
const LoopBodies = std.AutoArrayHashMapUnmanaged(LIR.CFStmtId, std.AutoHashMapUnmanaged(LIR.CFStmtId, void));

/// Runtime representation class of a committed layout, as far as this
/// emitter lowers values. Everything else is `other` and refused where used.
const Repr = enum {
    bool,
    str,
    zst,
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
    i128,
    u128,
    dec,
    f32,
    f64,
    other,

    fn numName(self: Repr) ?[]const u8 {
        return switch (self) {
            .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64, .i128, .u128, .dec, .f32, .f64 => @tagName(self),
            .bool, .str, .zst, .other => null,
        };
    }

    /// Fixed-width integer representations (not Dec, which is scaled).
    fn isInt(self: Repr) bool {
        return switch (self) {
            .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64, .i128, .u128 => true,
            .bool, .str, .zst, .dec, .f32, .f64, .other => false,
        };
    }

    /// 128-bit values are 8-limb tables compared through the runtime, not
    /// with Lua operators.
    fn isWide(self: Repr) bool {
        return switch (self) {
            .i128, .u128, .dec => true,
            .bool, .str, .zst, .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64, .f32, .f64, .other => false,
        };
    }
};

fn reprOf(idx: layout.Idx) Repr {
    return switch (idx) {
        .bool => .bool,
        .str => .str,
        .zst => .zst,
        .u8 => .u8,
        .i8 => .i8,
        .u16 => .u16,
        .i16 => .i16,
        .u32 => .u32,
        .i32 => .i32,
        .u64 => .u64,
        .i64 => .i64,
        .i128 => .i128,
        .u128 => .u128,
        .dec => .dec,
        .f32 => .f32,
        .f64 => .f64,
        .opaque_ptr, .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4, .u64x2, .i64x2 => .other,
        _ => .other,
    };
}

/// How a `LowLevel` op lowers. The table defaults to `unsupported`, so an op
/// is emitted only after it is listed here and implemented in the runtime.
const Lowering = enum {
    unsupported,
    wrapping_arith,
    checked_arith,
    compare,
    bool_not,
    int_to_str,
    dec_mul,
    division,
    sign,
    abs_diff,
    /// `rt.<op name>(args...)`: a runtime function named after the op.
    runtime_call,
    /// Like `runtime_call`, returning a Lua boolean (the target must be Bool).
    runtime_predicate,
    /// Number type conversion described by `numeric_conversion.getConversionSpec`.
    conversion,
    /// Integer bit operation: `rt.<stem>_<type>(args)`; see `bitStem`.
    bits,
    /// Overflow predicate: `rt.<op>_overflows_<type>(a, b)`, a Bool.
    overflows,
    /// Box construction, projection and copy-on-write preparation.
    box,
    /// Same bits, same Lua value (Dec <-> attos).
    identity,
    /// F32/F64 + - *: inline Lua arithmetic, F32 rounded through rt.f32.
    float_arith,
    /// floor, ceiling, sqrt on F32/F64: `rt.<stem>_<type>(a)`.
    float_unary,
    /// num_to_str: `rt.<type>_to_str(a)` for the operand's number type.
    num_to_str,
    /// `*_from_str`, `*_from_str_prefix`, `*_from_utf8_prefix`: the numparse
    /// port behind `rt.num_from_str` / `rt.num_from_prefix`.
    num_parse,
    /// Str.from_utf8 into its resolved Result layout (emitStrFromUtf8).
    str_from_utf8,
    /// Num.compare: the [Before, Same, After] tag from rt.order.
    num_order,
    /// Dict/Set hashing: `rt.hash_*` over the Hasher U64 (emitHasher).
    hasher,
    /// sin cos tan asin acos atan atan2 pow log: `rt.<stem>_<type>(args)`.
    math,
    /// num_from_le_bytes_unchecked: `rt.from_le_bytes_<type>(list, index)`
    /// for the result's integer type.
    from_le_bytes,
};

const lowerings = blk: {
    @setEvalBranchQuota(100_000);
    var table = std.EnumArray(LowLevel, Lowering).initFill(.unsupported);
    // Proven ops cannot overflow (the range prover minted them), so they
    // lower to the same modular arithmetic as the wrapping family.
    for ([_]LowLevel{
        .num_int_add_wrap,
        .num_int_sub_wrap,
        .num_int_mul_wrap,
        .num_int_add_proven_cannot_overflow,
        .num_int_sub_proven_cannot_overflow,
        .num_int_mul_proven_cannot_overflow,
    }) |op| table.set(op, .wrapping_arith);
    for ([_]LowLevel{ .num_int_add_crash_on_overflow, .num_int_sub_crash_on_overflow, .num_int_mul_crash_on_overflow }) |op| table.set(op, .checked_arith);
    for ([_]LowLevel{ .num_is_eq, .num_is_lt, .num_is_lte, .num_is_gt, .num_is_gte }) |op| table.set(op, .compare);
    table.set(.bool_not, .bool_not);
    for ([_]LowLevel{ .u8_to_str, .i8_to_str, .u16_to_str, .i16_to_str, .u32_to_str, .i32_to_str, .u64_to_str, .i64_to_str, .u128_to_str, .i128_to_str, .dec_to_str }) |op| table.set(op, .int_to_str);
    table.set(.dec_mul, .dec_mul);
    for ([_]LowLevel{ .num_div_by, .num_div_trunc_by, .num_rem_by, .num_mod_by, .num_div_by_checked, .num_div_trunc_by_checked, .num_rem_by_checked, .num_mod_by_checked }) |op| table.set(op, .division);
    for ([_]LowLevel{ .num_negate, .num_negate_checked, .num_abs, .num_abs_checked }) |op| table.set(op, .sign);
    table.set(.num_abs_diff, .abs_diff);
    for ([_]LowLevel{ .str_concat, .str_count_utf8_bytes, .str_get_utf8_byte_unsafe, .str_substring_unsafe, .str_drop_prefix, .str_drop_suffix, .str_inspect, .str_trim, .str_trim_start, .str_trim_end, .str_with_ascii_lowercased, .str_with_ascii_uppercased, .str_repeat, .str_split_first, .str_split_last, .str_drop_prefix_caseless_ascii, .str_split_on, .str_join_with, .str_to_utf8, .str_with_capacity, .str_reserve, .str_release_excess_capacity, .str_from_utf8_lossy }) |op| table.set(op, .runtime_call);
    for (std.enums.values(LowLevel)) |op| {
        if (numeric_conversion.getConversionSpec(op) != null) table.set(op, .conversion);
        if (op == .str_from_utf8) table.set(op, .str_from_utf8);
        if (op == .compare) table.set(op, .num_order);
        for ([_]LowLevel{ .num_sin, .num_cos, .num_tan, .num_asin, .num_acos, .num_atan, .num_atan2, .num_pow, .num_log }) |m| if (op == m) table.set(op, .math);
        if (op == .dict_pseudo_seed or std.mem.startsWith(u8, @tagName(op), "hasher_")) table.set(op, .hasher);
        if (numeric_conversion.getNumericParseSpec(op) != null or numeric_conversion.getNumericPrefixParseSpec(op) != null) table.set(op, .num_parse);
    }
    for ([_]LowLevel{ .num_shift_left_by, .num_shift_right_by, .num_shift_right_zf_by, .num_bitwise_and, .num_bitwise_or, .num_bitwise_xor, .num_bitwise_not, .num_count_one_bits, .num_count_leading_zero_bits, .num_count_trailing_zero_bits }) |op| table.set(op, .bits);
    for ([_]LowLevel{ .box_box, .box_unbox, .box_unbox_borrowed, .box_prepare_update }) |op| table.set(op, .box);
    for ([_]LowLevel{ .dec_to_attos, .dec_from_attos, .erased_capture_load }) |op| table.set(op, .identity);
    for ([_]LowLevel{ .num_float_add, .num_float_sub, .num_float_mul }) |op| table.set(op, .float_arith);
    for ([_]LowLevel{ .num_floor, .num_ceiling, .num_sqrt }) |op| table.set(op, .float_unary);
    table.set(.num_to_str, .num_to_str);
    table.set(.num_from_le_bytes_unchecked, .from_le_bytes);
    for ([_]LowLevel{ .f32_to_str, .f64_to_str, .f64_to_bits, .f64_from_bits, .f32_to_bits, .f32_from_bits }) |op| table.set(op, .runtime_call);
    for ([_]LowLevel{ .crypto_sha256_hash_bytes, .crypto_sha256_hasher_empty, .crypto_sha256_hasher_write, .crypto_sha256_hasher_finish, .crypto_blake3_hash_bytes, .crypto_blake3_hasher_empty, .crypto_blake3_hasher_write, .crypto_blake3_hasher_finish }) |op| table.set(op, .runtime_call);
    for ([_]LowLevel{ .num_int_add_overflows, .num_int_sub_overflows, .num_int_mul_overflows }) |op| table.set(op, .overflows);
    for ([_]LowLevel{ .str_is_eq, .str_contains, .str_starts_with, .str_ends_with, .str_caseless_ascii_equals, .str_is_eq_static_small, .str_static_small_word_eq, .str_static_small_word_caseless_eq }) |op| table.set(op, .runtime_predicate);
    break :blk table;
};

/// The eight vector layouts (`builtins.simd.Kind`); their tag names are the
/// `rt.V` kind descriptors.
/// I64/U64 values of smaller magnitude are emitted and passed as Lua numbers,
/// which represent them exactly (runtime.lua, "64-bit integers").
const lua_exact_int_limit: u64 = 1 << 53;
const vector_layouts = [_]layout.Idx{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4, .u64x2, .i64x2 };

fn isVectorLayout(idx: layout.Idx) bool {
    return std.mem.findScalar(layout.Idx, &vector_layouts, idx) != null;
}

/// simd.lua entry point and argument shape for each SIMD op, in
/// `builtins.simd.Op` order (`LowLevel.simdOpIndex`). Shape letters: `A`/`R`
/// the argument/result kind descriptor, `0`-`2` the arguments, `Q` whether
/// ARC proved argument 1 (the list) unique.
const simd_shapes = [_]ListShape{
    .{ "load", "01" },
    .{ "store", "012Q" },
    .{ "append", "01Q" },
    .{ "splat", "R0" },
    .{ "get_lane", "A01" },
    .{ "with_lane", "A012" },
    .{ "to_u128_bits", "0" },
    .{ "from_u128_bits", "0" },
    .{ "add_wrap", "A01" },
    .{ "sub_wrap", "A01" },
    .{ "add_sat", "A01" },
    .{ "sub_sat", "A01" },
    .{ "neg_wrap", "A0" },
    .{ "abs_wrap", "A0" },
    .{ "min", "A01" },
    .{ "max", "A01" },
    .{ "abs_diff", "A01" },
    .{ "avg_rounded", "A01" },
    .{ "mul_wrap", "A01" },
    .{ "mul_high", "A01" },
    .{ "mul_q15_sat", "A01" },
    .{ "mul_wide_lo", "AR01" },
    .{ "mul_wide_hi", "AR01" },
    .{ "dot_pairs", "A01" },
    .{ "dot_pairs_sat", "A01" },
    .{ "sad", "A01" },
    .{ "band", "01" },
    .{ "bor", "01" },
    .{ "bxor", "01" },
    .{ "bnot", "0" },
    .{ "bit_select", "012" },
    .{ "eq_lanes", "A01" },
    .{ "gt_lanes", "A01" },
    .{ "gte_lanes", "A01" },
    .{ "bitmask", "A0" },
    .{ "shl_wrap", "A01" },
    .{ "shr_wrap", "A01" },
    .{ "shr_zf_wrap", "A01" },
    .{ "shr_rounded", "A01" },
    .{ "interleave_lo", "A01" },
    .{ "interleave_hi", "A01" },
    .{ "even_lanes", "A01" },
    .{ "odd_lanes", "A01" },
    .{ "reverse_lanes", "A0" },
    .{ "table_lookup", "A01" },
    .{ "concat_shift_bytes", "012" },
    .{ "widen_lo", "AR0" },
    .{ "widen_hi", "AR0" },
    .{ "pairwise_add_widen", "AR0" },
    .{ "narrow_wrap", "AR01" },
    .{ "narrow_sat", "AR01" },
    .{ "sum_lanes", "A0" },
    .{ "sum_lanes", "A0" },
    .{ "clmul_lo", "01" },
    .{ "clmul_hi", "01" },
};

comptime {
    std.debug.assert(simd_shapes.len == @intFromEnum(LowLevel.simd_clmul_hi) - @intFromEnum(LowLevel.simd_load_16_unchecked) + 1);
}

/// list.lua entry point and argument shape for each List low-level op; see
/// `Emitter.emitListOp` for the shape letters. Ops absent here are not list ops.
const ListShape = struct { []const u8, []const u8 };
const list_shapes = blk: {
    @setEvalBranchQuota(10_000);
    var t = std.EnumArray(LowLevel, ?ListShape).initFill(null);
    t.set(.list_len, .{ "len", "0" });
    t.set(.list_capacity, .{ "capacity", "0" });
    t.set(.list_slack_unique, .{ "slack_unique", "0" });
    t.set(.list_owned_unique, .{ "owned_unique", "0" });
    t.set(.list_get_unsafe, .{ "get_unsafe", "01W" });
    t.set(.list_map_extract_unsafe, .{ "get_unsafe", "01W" });
    t.set(.list_append_unsafe, .{ "append_unsafe", "0bW" });
    t.set(.list_concat, .{ "concat", "01WIDPQ" });
    t.set(.list_append_range_within, .{ "append_range_within", "012WIDP" });
    t.set(.list_copy_range_within, .{ "copy_range_within", "0123WID" });
    t.set(.list_append_range_within_unsafe, .{ "append_range_within_unsafe", "012WI" });
    t.set(.list_append_le_bytes, .{ "append_le_bytes", "012P" });
    t.set(.list_append_sublist, .{ "append_sublist", "0123WIDP" });
    t.set(.list_prepend, .{ "prepend", "0bWIDP" });
    t.set(.list_swap, .{ "swap", "012WIDP" });
    t.set(.list_map_can_reuse, .{ "map_can_reuse", "0X" });
    t.set(.list_map_write_unsafe, .{ "map_write_unsafe", "01cW" });
    t.set(.list_sublist, .{ "sublist", "01WDP" });
    t.set(.list_sort_with, .{ "sort_with", "01WIDPMU" });
    t.set(.list_sublist_borrowed, .{ "sublist_borrowed", "01WR" });
    t.set(.list_drop_at, .{ "drop_at", "01WIDP" });
    t.set(.list_set, .{ "set", "01cWIDP" });
    t.set(.list_set_in_place_unsafe, .{ "set", "01cWIDP" });
    t.set(.list_with_capacity, .{ "with_capacity", "0W" });
    t.set(.list_reserve, .{ "reserve", "01WIDP" });
    t.set(.list_release_excess_capacity, .{ "release_excess_capacity", "0WIDP" });
    t.set(.list_first, .{ "first", "0WM" });
    t.set(.list_last, .{ "last", "0WM" });
    t.set(.list_drop_first, .{ "drop_first", "0WDP" });
    t.set(.list_drop_last, .{ "drop_last", "0WDP" });
    t.set(.list_take_first, .{ "take_first", "01WDP" });
    t.set(.list_take_last, .{ "take_last", "01WDP" });
    t.set(.list_reverse, .{ "reverse", "0WIDP" });
    t.set(.list_split_first, .{ "split_first", "0WIDPSM" });
    t.set(.list_split_last, .{ "split_last", "0WIDPSM" });
    t.set(.list_replace_unsafe, .{ "replace", "01cWIDP" });
    t.set(.list_map_prepare_reuse, .{ "", "0" });
    t.set(.list_map_cast_unsafe, .{ "", "0" });
    break :blk t;
};

const Emitter = struct {
    gpa: Allocator,
    input: Input,
    options: Options,
    out: std.Io.Writer.Allocating,
    unsupported_reason: ?[]const u8 = null,
    reason_buf: [256]u8 = undefined,
    /// Statements already emitted in the current procedure; a second visit
    /// means a shared continuation, which this emitter does not lower yet.
    visited: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty,
    /// Encoded RC helper keys called so far; defined after the procedures.
    rc_helpers: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    /// Leaf forms of element RC helpers for flat list storage (`R.dL42`),
    /// keyed like `rc_helpers`; defined with them.
    leaf_rc_helpers: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    /// Host boundary converters for flat list storage (`emitHostConverters`):
    /// layouts needing `R.h` (to the host) and `R.g` (from the host), and the
    /// memoized answer of `needsHostConversion`.
    host_to: std.AutoArrayHashMapUnmanaged(layout.Idx, void) = .empty,
    host_from: std.AutoArrayHashMapUnmanaged(layout.Idx, void) = .empty,
    host_conversion: std.AutoHashMapUnmanaged(layout.Idx, bool) = .empty,
    /// Layouts whose materializer `R.m<layout>` (leaves -> table) or unpacker
    /// `R.u<layout>` (table -> leaves) the emitted code calls, each with a
    /// shape node of that layout; defined after the procedures.
    materializers: std.AutoArrayHashMapUnmanaged(layout.Idx, u32) = .empty,
    unpackers: std.AutoArrayHashMapUnmanaged(layout.Idx, u32) = .empty,
    /// Per procedure: statements reached along more than one edge. Each is
    /// emitted once as a top-level labeled segment (`::sN::`) and entered by
    /// `goto`, as is every join body.
    shared: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty,
    /// Per procedure: the body statement of each join point.
    join_bodies: std.AutoHashMapUnmanaged(LIR.JoinPointId, LIR.CFStmtId) = .empty,
    /// Per procedure: segments queued for emission, and those already emitted.
    segment_queue: std.ArrayList(LIR.CFStmtId) = .empty,
    segment_done: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty,
    /// Per procedure: each LIR local's Lua slot (`assignSlots`). Slots below
    /// `max_frame_locals` are Lua locals `rN`; the rest live in the frame
    /// table `S`.
    slot_of: std.AutoHashMapUnmanaged(LIR.LocalId, u32) = .empty,
    /// Static data slots read so far; built once at load as `SD[id]`.
    static_slots: std.AutoArrayHashMapUnmanaged(u32, layout.Idx) = .empty,
    /// 128-bit constants procedures read, by bit pattern; built once at load
    /// as `WK[index + 1]`.
    wide_consts: std.AutoArrayHashMapUnmanaged(u128, void) = .empty,
    /// Stack slots the current procedure accounts per frame (DEPTH).
    frame_slots: usize = 0,
    /// Set while emitting a runtime operation's operands: Str operands are
    /// passed through `rt.str`, since only view-aware operations
    /// (`viewAwareStrOp`) accept the runtime's Str views.
    str_operands: bool = false,
    /// Leaf shapes of struct and tag-union layouts (null: stays a table),
    /// for the whole program.
    shapes: std.AutoHashMapUnmanaged(layout.Idx, ?u32) = .empty,
    shape_nodes: std.ArrayList(ShapeNode) = .empty,
    shape_children: std.ArrayList(u32) = .empty,
    /// Per procedure: the slots holding each flattened local's leaves.
    leaf_slots_of: std.AutoHashMapUnmanaged(LIR.LocalId, struct { first: u32, count: u32 }) = .empty,
    leaf_slot_pool: std.ArrayList(u32) = .empty,
    /// Procedures with the flattened ABI: flattened parameters arrive as
    /// their leaves and a flattened result returns as multiple values. The
    /// rest (roots, platform entrypoints, erased callables) take and return
    /// Lua tables, since Lua code outside the emitter calls them.
    flat_abi: std.AutoHashMapUnmanaged(LIR.LirProcSpecId, void) = .empty,
    /// A flattened local just written whole to the scratch `rS`; its leaves
    /// are loaded before the next statement.
    pending_unpack: ?LIR.LocalId = null,
    /// Set while emitHasher writes into a Hasher local's single leaf.
    hasher_into_leaf: bool = false,
    /// The procedure being emitted: its ABI and result layout.
    current_flat_abi: bool = false,
    current_ret_layout: layout.Idx = .zst,

    fn deinit(self: *Emitter) void {
        self.out.deinit();
        self.visited.deinit(self.gpa);
        self.rc_helpers.deinit(self.gpa);
        self.leaf_rc_helpers.deinit(self.gpa);
        self.host_to.deinit(self.gpa);
        self.host_from.deinit(self.gpa);
        self.host_conversion.deinit(self.gpa);
        self.materializers.deinit(self.gpa);
        self.unpackers.deinit(self.gpa);
        self.shared.deinit(self.gpa);
        self.join_bodies.deinit(self.gpa);
        self.segment_queue.deinit(self.gpa);
        self.segment_done.deinit(self.gpa);
        self.slot_of.deinit(self.gpa);
        self.shapes.deinit(self.gpa);
        self.shape_nodes.deinit(self.gpa);
        self.shape_children.deinit(self.gpa);
        self.leaf_slots_of.deinit(self.gpa);
        self.leaf_slot_pool.deinit(self.gpa);
        self.flat_abi.deinit(self.gpa);
        self.static_slots.deinit(self.gpa);
        self.wide_consts.deinit(self.gpa);
    }

    fn w(self: *Emitter) *std.Io.Writer {
        return &self.out.writer;
    }

    fn store(self: *Emitter) *const LirStore {
        return self.input.store;
    }

    fn refuse(self: *Emitter, comptime fmt: []const u8, args: anytype) error{Unsupported} {
        self.unsupported_reason = std.fmt.bufPrint(&self.reason_buf, fmt, args) catch fmt;
        return error.Unsupported;
    }

    fn emitAll(self: *Emitter) EmitError!void {
        const procs = try self.reachableProcs();
        defer self.gpa.free(procs);

        const out = self.w();
        try out.writeAll("-- Generated by the roc_luajit LIR-to-LuaJIT emitter. Do not edit.\n");
        if (self.input.entrypoints.len != 0) try out.writeAll("local HOST = ...\n");
        try out.writeAll("local W = (function()\n");
        try out.writeAll(wide_source);
        try out.writeAll("\nend)()\nlocal I128 = (function()\n");
        try out.writeAll(int128_source);
        try out.writeAll("\nend)()(W)\nlocal LIST = (function()\n");
        try out.writeAll(list_source);
        try out.writeAll("\nend)()\nlocal FLOAT = (function()\n");
        try out.writeAll(float_source);
        try out.writeAll("\nend)()\n");
        try out.writeAll(lazy_module_source);
        // sort.lua returns the module; the others return its constructor,
        // which the runtime calls with its dependencies.
        try out.writeAll("local SORT = LAZY(function() return COMPILE(" ++ lazy_open);
        try out.writeAll(sort_source);
        try out.writeAll(lazy_close ++ ", \"sort\") end)\n");
        for ([_]struct { []const u8, []const u8, []const u8 }{
            .{ "NUMPARSE", "numparse", numparse_source },
            .{ "FMATH", "fmath", fmath_source },
            .{ "SIMD", "simd", simd_source },
            .{ "CRYPTO", "crypto", crypto_source },
        }) |module| {
            try out.print("local {s} = function(...)\n    local args = {{ ... }}\n    return LAZY(function() return COMPILE(" ++ lazy_open, .{module[0]});
            try out.writeAll(module[2]);
            try out.print(lazy_close ++ ", \"{s}\")(unpack(args)) end)\nend\n", .{module[1]});
        }
        try out.writeAll("local rt = (function(...)\n");
        try out.writeAll(runtime_source);
        try out.writeAll("\nend)(W, I128, LIST, FLOAT, SORT, NUMPARSE, FMATH, SIMD, CRYPTO)\nlocal bit = require(\"bit\")\nlocal P = {}\nlocal R = {}\nlocal SD = {}\nlocal WK = {}\n");
        try out.writeAll(stack_hop_source);
        self.flat_abi.clearRetainingCapacity();
        for (procs) |proc_id| {
            const p = self.store().getProcSpec(proc_id);
            if (p.hosted != null or p.body == null or p.abi != .roc or self.isExternalRoot(proc_id)) continue;
            try self.flat_abi.put(self.gpa, proc_id, {});
        }
        for (procs) |proc_id| try self.emitProc(proc_id);
        try self.emitWideConsts();
        try self.emitStaticData();
        // Code outside the emitted procedures (the host, rt.run_main) calls
        // the roots; their wrappers are written before the helpers they queue.
        var roots: std.Io.Writer.Allocating = .init(self.gpa);
        defer roots.deinit();
        if (self.input.entrypoints.len == 0) {
            try roots.writer.writeAll("rt.run_main(");
            try self.emitRootCallee(&roots.writer, self.input.main_proc);
            try roots.writer.writeAll(")\n");
        } else {
            try roots.writer.writeAll("return { entrypoints = {");
            for (self.input.entrypoints, 0..) |entry, i| {
                if (i != 0) try roots.writer.writeAll(",");
                try roots.writer.writeAll(" [");
                try emitLuaString(&roots.writer, entry.name);
                try roots.writer.writeAll("] = ");
                try self.emitRootCallee(&roots.writer, entry.proc);
            }
            try roots.writer.writeAll(" }, rt = rt }\n");
        }
        try self.emitHostConverters();
        try self.emitRcHelpers();
        try self.emitShapeHelpers();
        if (self.static_slots.count() != 0) try out.writeAll("init_static_data()\n");
        try out.writeAll(roots.written());
    }

    /// A root as code outside the emitted procedures calls it: `P[n]`, or a
    /// wrapper converting flat lists in its arguments from the host's form
    /// and in its result to it (hosts read and build lists with one value
    /// per element).
    fn emitRootCallee(self: *Emitter, out: *std.Io.Writer, proc_id: LIR.LirProcSpecId) EmitError!void {
        const spec = self.store().getProcSpec(proc_id);
        const params = self.store().getLocalSpan(spec.args);
        var convert = try self.needsHostConversion(spec.ret_layout);
        for (0..params.len) |i| convert = convert or try self.needsHostConversion(self.layoutOfLocal(GuardedList.at(params, i)));
        if (!convert) return out.print("P[{d}]", .{@intFromEnum(proc_id)});
        try out.writeAll("function(");
        for (0..params.len) |i| try out.print("{s}a{d}", .{ if (i == 0) "" else ", ", i + 1 });
        try out.writeAll(") return ");
        const ret_conv = try self.needsHostConversion(spec.ret_layout);
        if (ret_conv) {
            try self.host_to.put(self.gpa, spec.ret_layout, {});
            try out.print("R.h{d}(", .{@intFromEnum(spec.ret_layout)});
        }
        try out.print("P[{d}](", .{@intFromEnum(proc_id)});
        for (0..params.len) |i| {
            if (i != 0) try out.writeAll(", ");
            const p = self.layoutOfLocal(GuardedList.at(params, i));
            if (try self.needsHostConversion(p)) {
                try self.host_from.put(self.gpa, p, {});
                try out.print("R.g{d}(a{d})", .{ @intFromEnum(p), i + 1 });
            } else try out.print("a{d}", .{i + 1});
        }
        try out.writeAll(if (ret_conv) ")) end" else ") end");
    }

    /// Whether Lua code outside the emitted procedures calls this procedure:
    /// the differential root, or a platform entrypoint.
    fn isExternalRoot(self: *Emitter, proc_id: LIR.LirProcSpecId) bool {
        if (self.input.entrypoints.len == 0) return proc_id == self.input.main_proc;
        for (self.input.entrypoints) |entry| {
            if (entry.proc == proc_id) return true;
        }
        return false;
    }

    /// A call to a flattened-ABI procedure: flattened arguments pass their
    /// leaves, and a flattened result arrives as multiple values straight
    /// into the target's leaves.
    fn emitFlatCall(self: *Emitter, target: LIR.LocalId, proc_id: LIR.LirProcSpecId, args_span: LIR.LocalSpan, depth: usize) EmitError!void {
        const callee_spec = self.store().getProcSpec(proc_id);
        const params = self.store().getLocalSpan(callee_spec.args);
        const call_args = self.store().getLocalSpan(args_span);
        if (params.len != call_args.len) return self.refuse("call arity {d} for {d} parameters", .{ call_args.len, params.len });
        if (try self.shapeOf(callee_spec.ret_layout)) |ret_shape| {
            const dst_shape = self.localShape(target) orelse return self.refuse("flattened result into a table local", .{});
            if (!self.sameShape(ret_shape, dst_shape)) return self.refuse("flattened result shape mismatch", .{});
            const dst = self.leafSlots(target).?;
            try self.indent(depth);
            if (dst.len != 0) {
                try self.emitLeafList(dst);
                try self.w().writeAll(" = ");
            }
        } else {
            try self.beginAssign(target, depth);
        }
        try self.w().print("P[{d}](", .{@intFromEnum(proc_id)});
        var first = true;
        for (0..params.len) |i| {
            const arg = GuardedList.at(call_args, i);
            const param_layout = self.layoutOfLocal(GuardedList.at(params, i));
            if (try self.shapeOf(param_layout)) |param_shape| {
                const arg_shape = self.localShape(arg) orelse return self.refuse("flattened parameter from a table local", .{});
                if (!self.sameShape(param_shape, arg_shape)) return self.refuse("flattened argument shape mismatch", .{});
                const leaves = self.leafSlots(arg).?;
                if (leaves.len == 0) continue;
                if (!first) try self.w().writeAll(", ");
                try self.emitLeafList(leaves);
            } else {
                if (!first) try self.w().writeAll(", ");
                try self.emitLocal(arg);
            }
            first = false;
        }
        try self.w().writeAll(")\n");
    }

    /// Procedures reachable from `main_proc` through `assign_call`, sorted.
    fn reachableProcs(self: *Emitter) EmitError![]LIR.LirProcSpecId {
        var seen: std.AutoArrayHashMapUnmanaged(LIR.LirProcSpecId, void) = .empty;
        defer seen.deinit(self.gpa);
        var stack: std.ArrayList(LIR.CFStmtId) = .empty;
        defer stack.deinit(self.gpa);
        var stmt_seen: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty;
        defer stmt_seen.deinit(self.gpa);

        if (self.input.entrypoints.len == 0) try seen.put(self.gpa, self.input.main_proc, {});
        for (self.input.entrypoints) |entry| try seen.put(self.gpa, entry.proc, {});
        var next: usize = 0;
        while (next < seen.count()) : (next += 1) {
            const proc = self.store().getProcSpec(seen.keys()[next]);
            const body = proc.body orelse continue;
            stack.clearRetainingCapacity();
            try stack.append(self.gpa, body);
            while (stack.pop()) |stmt_id| {
                if ((try stmt_seen.getOrPut(self.gpa, stmt_id)).found_existing) continue;
                const stmt = self.store().getCFStmt(stmt_id);
                if (callee(stmt)) |proc_id| try seen.put(self.gpa, proc_id, {});
                try self.pushSuccessors(&stack, stmt);
            }
        }

        const ids = try self.gpa.dupe(LIR.LirProcSpecId, seen.keys());
        std.mem.sort(LIR.LirProcSpecId, ids, {}, struct {
            fn lessThan(_: void, a: LIR.LirProcSpecId, b: LIR.LirProcSpecId) bool {
                return @intFromEnum(a) < @intFromEnum(b);
            }
        }.lessThan);
        return ids;
    }

    fn pushSuccessors(self: *Emitter, stack: *std.ArrayList(LIR.CFStmtId), stmt: LIR.CFStmt) Allocator.Error!void {
        switch (stmt) {
            inline .init_uninitialized,
            .assign_ref,
            .assign_literal,
            .assign_call,
            .assign_call_erased,
            .assign_packed_erased_fn,
            .assign_boxy_desc_ref,
            .assign_boxy_dict_ref,
            .assign_boxy_box,
            .assign_boxy_reuse_box,
            .assign_boxy_unbox,
            .assign_boxy_adapt,
            .assign_boxy_inspect,
            .assign_boxy_tag,
            .assign_boxy_tag_payload,
            .assign_call_dict,
            .assign_low_level,
            .assign_list,
            .assign_struct,
            .assign_tag,
            .store_struct,
            .store_tag,
            .set_local,
            .debug,
            .expect,
            .comptime_branch_taken,
            .incref,
            .decref,
            .decref_if_initialized,
            .free,
            => |s| try stack.append(self.gpa, s.next),
            .boxy_tag_match => |s| {
                try stack.append(self.gpa, s.on_match);
                try stack.append(self.gpa, s.on_miss);
            },
            .switch_stmt => |s| {
                const branches = self.store().getCFSwitchBranches(s.branches);
                for (0..branches.len) |i| try stack.append(self.gpa, GuardedList.at(branches, i).body);
                try stack.append(self.gpa, s.default_branch);
            },
            .switch_initialized_payload => |s| {
                try stack.append(self.gpa, s.initialized_branch);
                try stack.append(self.gpa, s.uninitialized_branch);
            },
            .str_match => |s| {
                try stack.append(self.gpa, s.on_match);
                try stack.append(self.gpa, s.on_miss);
            },
            .str_match_set => |s| {
                const arms = self.store().getStrMatchArms(s.arms);
                for (0..arms.len) |i| try stack.append(self.gpa, GuardedList.at(arms, i).on_match);
                try stack.append(self.gpa, s.on_miss);
            },
            .join => |j| {
                try stack.append(self.gpa, j.body);
                try stack.append(self.gpa, j.remainder);
            },
            .expect_err, .runtime_error, .comptime_exhaustiveness_failed, .loop_continue, .loop_break, .jump, .ret, .crash => {},
        }
    }

    fn emitProc(self: *Emitter, proc_id: LIR.LirProcSpecId) EmitError!void {
        const proc = self.store().getProcSpec(proc_id);
        if (proc.hosted) |hosted| {
            // Hosted procedures are the platform's: bound by symbol at load.
            if (self.input.entrypoints.len == 0) return self.refuse("hosted procedure call", .{});
            // Hosts read and build lists with one value per element, so
            // arguments and results holding flat lists are converted here.
            const params = self.store().getLocalSpan(proc.args);
            var convert = try self.needsHostConversion(proc.ret_layout);
            for (0..params.len) |i| convert = convert or try self.needsHostConversion(self.layoutOfLocal(GuardedList.at(params, i)));
            try self.w().print("P[{d}] = ", .{@intFromEnum(proc_id)});
            if (convert) {
                try self.w().writeAll("(function(f) return function(");
                for (0..params.len) |i| try self.w().print("{s}a{d}", .{ if (i == 0) "" else ", ", i + 1 });
                try self.w().writeAll(") return ");
                const ret_conv = try self.needsHostConversion(proc.ret_layout);
                if (ret_conv) try self.w().print("R.g{d}(", .{@intFromEnum(proc.ret_layout)});
                try self.w().writeAll("f(");
                for (0..params.len) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    const p = self.layoutOfLocal(GuardedList.at(params, i));
                    if (try self.needsHostConversion(p)) {
                        try self.host_to.put(self.gpa, p, {});
                        try self.w().print("R.h{d}(a{d})", .{ @intFromEnum(p), i + 1 });
                    } else try self.w().print("a{d}", .{i + 1});
                }
                if (ret_conv) {
                    try self.host_from.put(self.gpa, proc.ret_layout, {});
                    try self.w().writeAll(")");
                }
                try self.w().writeAll(") end end)(");
            }
            try self.w().writeAll("rt.hosted(HOST, ");
            try emitLuaString(self.w(), self.store().getString(hosted.symbol));
            return self.w().writeAll(if (convert) "))\n" else ")\n");
        }
        switch (proc.abi) {
            .roc => {},
            // Erased ABI: explicit args, then the capture and the reuse slot.
            .erased_callable => {},
        }
        const body = proc.body orelse return self.refuse("procedure without body", .{});

        const out = self.w();
        const args = self.store().getLocalSpan(proc.args);
        if (args.len > max_frame_locals) return self.refuse("{d} parameters exceed the LuaJIT local limit", .{args.len});
        try self.planSegments(body);
        const slots = try self.assignSlots(args, body);
        const flat = self.flat_abi.contains(proc_id);
        self.current_flat_abi = flat;
        self.current_ret_layout = proc.ret_layout;
        self.pending_unpack = null;

        // Lua parameters: a flattened argument's leaves (flattened ABI) or a
        // table `aN` unpacked on entry (table ABI); other arguments' slots.
        var params: std.ArrayList(u8) = .empty;
        defer params.deinit(self.gpa);
        var param_slot: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer param_slot.deinit(self.gpa);
        for (0..args.len) |i| {
            const arg = GuardedList.at(args, i);
            const arg_slots: []const u32 = if (self.leafSlots(arg)) |leaves|
                (if (flat) leaves else &.{})
            else
                &.{self.slot_of.get(arg).?};
            if (self.leafSlots(arg) != null and !flat) {
                if (params.items.len != 0) try params.appendSlice(self.gpa, ", ");
                try params.print(self.gpa, "a{d}", .{i});
            }
            for (arg_slots) |slot| {
                if (slot >= max_frame_locals) return self.refuse("parameter slot beyond the LuaJIT local limit", .{});
                try param_slot.put(self.gpa, slot, {});
                if (params.items.len != 0) try params.appendSlice(self.gpa, ", ");
                try params.print(self.gpa, "r{d}", .{slot});
            }
        }
        try out.print("P[{d}] = function({s})\n", .{ @intFromEnum(proc_id), params.items });

        // Lua locals up to the limit; the rest live in the frame table S.
        const declared = @min(slots, max_frame_locals);
        var first_local = true;
        for (0..declared) |slot| {
            if (param_slot.contains(@intCast(slot))) continue;
            try out.writeAll(if (first_local) "\tlocal " else ", ");
            try out.print("r{d}", .{slot});
            first_local = false;
        }
        if (self.leaf_slots_of.count() != 0) {
            try out.writeAll(if (first_local) "\tlocal rS" else ", rS");
            first_local = false;
        }
        if (!first_local) try out.writeAll("\n");
        if (slots > max_frame_locals) try out.writeAll("\tlocal S = {}\n");

        // Deep recursion: account this frame against the coroutine's stack
        // (see `stack_hop_source`) and continue on a fresh one near its limit.
        self.frame_slots = declared + 1 + frame_slot_margin;
        try out.print("\tif DEPTH > {d} then return HOP(P[{d}]{s}{s}) end\n\tDEPTH = DEPTH + {d}\n", .{
            hop_depth_slots, @intFromEnum(proc_id), if (params.items.len != 0) ", " else "", params.items, self.frame_slots,
        });
        // Table-ABI arguments that are flattened in the body.
        if (!flat) {
            for (0..args.len) |i| {
                const arg = GuardedList.at(args, i);
                const leaves = self.leafSlots(arg) orelse continue;
                const path = try std.fmt.allocPrint(self.gpa, "a{d}", .{i});
                defer self.gpa.free(path);
                try self.emitUnpack(self.localShape(arg).?, leaves, path, 1);
            }
        }

        self.visited.clearRetainingCapacity();
        try self.emitChain(body, 1, true);
        var order: std.ArrayList(LIR.CFStmtId) = .empty;
        defer order.deinit(self.gpa);
        var loops: LoopBodies = .empty;
        defer {
            for (loops.values()) |*members| members.deinit(self.gpa);
            loops.deinit(self.gpa);
        }
        try self.segmentOrder(body, &order, &loops);
        try self.emitSegments(order.items[1..], &loops, null, 1);
        // Every queued segment is reachable from the entry, so the order
        // above has emitted it.
        while (self.segment_queue.pop()) |segment| {
            if (!self.segment_done.contains(segment)) return self.refuse("segment s{d} outside the layout order", .{@intFromEnum(segment)});
        }
        try out.writeAll("end\n");
    }

    /// Find this procedure's shared statements (more than one incoming edge)
    /// and join bodies, which are emitted as top-level labeled segments so
    /// every `goto` sees its label.
    fn planSegments(self: *Emitter, body: LIR.CFStmtId) EmitError!void {
        self.shared.clearRetainingCapacity();
        self.join_bodies.clearRetainingCapacity();
        self.segment_queue.clearRetainingCapacity();
        self.segment_done.clearRetainingCapacity();
        var incoming: std.AutoHashMapUnmanaged(LIR.CFStmtId, u32) = .empty;
        defer incoming.deinit(self.gpa);
        var stack: std.ArrayList(LIR.CFStmtId) = .empty;
        defer stack.deinit(self.gpa);
        var successors: std.ArrayList(LIR.CFStmtId) = .empty;
        defer successors.deinit(self.gpa);
        try stack.append(self.gpa, body);
        try incoming.put(self.gpa, body, 1);
        while (stack.pop()) |id| {
            const stmt = self.store().getCFStmt(id);
            if (stmt == .join) try self.join_bodies.put(self.gpa, stmt.join.id, stmt.join.body);
            successors.clearRetainingCapacity();
            try self.pushSuccessors(&successors, stmt);
            for (successors.items) |next| {
                const entry = try incoming.getOrPut(self.gpa, next);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                    try stack.append(self.gpa, next);
                }
            }
        }
        var it = incoming.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > 1) try self.shared.put(self.gpa, entry.key_ptr.*, {});
        }
    }

    /// Emit labeled segments in layout order. A loop header opens a
    /// `while true do` block holding the header and every other segment of
    /// its loop, nested loops inside: a backward `goto` is a plain JMP, which
    /// LuaJIT never counts as a loop, while the LOOP bytecode of `while true`
    /// is counted and closes traces, and a root trace aborts ("leaving loop")
    /// whenever it records bytecode outside that block. Only the header is
    /// entered from outside the block (the layout refuses other loops), so
    /// every `goto` sees its label.
    fn emitSegments(self: *Emitter, order: []const LIR.CFStmtId, loops: *const LoopBodies, region: ?*const std.AutoHashMapUnmanaged(LIR.CFStmtId, void), depth: usize) EmitError!void {
        for (order) |segment| {
            if (region) |members| {
                if (!members.contains(segment)) continue;
            }
            if ((try self.segment_done.getOrPut(self.gpa, segment)).found_existing) continue;
            try self.indent(depth);
            try self.w().print("::s{d}::\n", .{@intFromEnum(segment)});
            if (loops.getPtr(segment)) |members| {
                try self.indent(depth);
                try self.w().writeAll("while true do\n");
                try self.emitChain(segment, depth + 1, true);
                try self.emitSegments(order, loops, members, depth + 1);
                try self.indent(depth);
                try self.w().writeAll("end\n");
            } else {
                try self.emitChain(segment, depth, true);
            }
        }
    }

    /// Segment layout: reverse postorder of the segment graph (a segment's
    /// chain reaches another segment by a `goto`), so only control-flow back
    /// edges jump backward, plus each loop's members (natural loops: the
    /// target of a back edge and every segment reaching that edge's source
    /// without passing it). A merge point laid out before its predecessor
    /// made the recorder abort traces until blacklisted. Loops entered other
    /// than through their header (irreducible control flow) are refused.
    fn segmentOrder(
        self: *Emitter,
        body: LIR.CFStmtId,
        order: *std.ArrayList(LIR.CFStmtId),
        loops: *LoopBodies,
    ) EmitError!void {
        const gpa = self.gpa;
        var is_body: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty;
        defer is_body.deinit(gpa);
        var bodies = self.join_bodies.valueIterator();
        while (bodies.next()) |join_body| try is_body.put(gpa, join_body.*, {});

        // Edges from each segment (the entry included) to the segments its
        // inline statements reach.
        var edges: std.AutoArrayHashMapUnmanaged(LIR.CFStmtId, std.ArrayList(LIR.CFStmtId)) = .empty;
        defer {
            for (edges.values()) |*list| list.deinit(gpa);
            edges.deinit(gpa);
        }
        var pending: std.ArrayList(LIR.CFStmtId) = .empty;
        defer pending.deinit(gpa);
        var stack: std.ArrayList(LIR.CFStmtId) = .empty;
        defer stack.deinit(gpa);
        var seen: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty;
        defer seen.deinit(gpa);
        try pending.append(gpa, body);
        while (pending.pop()) |segment| {
            const entry = try edges.getOrPut(gpa, segment);
            if (entry.found_existing) continue;
            entry.value_ptr.* = .empty;
            stack.clearRetainingCapacity();
            seen.clearRetainingCapacity();
            try stack.append(gpa, segment);
            var start = true;
            while (stack.pop()) |id| {
                // Any arrival at a segment other than the walk's own start
                // is an edge, including a loop back to this segment.
                if (!start and (self.shared.contains(id) or is_body.contains(id))) {
                    try edges.getPtr(segment).?.append(gpa, id);
                    try pending.append(gpa, id);
                    continue;
                }
                start = false;
                if ((try seen.getOrPut(gpa, id)).found_existing) continue;
                const stmt = self.store().getCFStmt(id);
                try self.pushSuccessors(&stack, stmt);
                if (stmt == .jump) {
                    if (self.join_bodies.get(stmt.jump.target)) |join_body| try stack.append(gpa, join_body);
                }
            }
        }

        // Iterative depth-first postorder from the entry, then reversed.
        var visited: std.AutoHashMapUnmanaged(LIR.CFStmtId, void) = .empty;
        defer visited.deinit(gpa);
        const Frame = struct { segment: LIR.CFStmtId, next: usize };
        var frames: std.ArrayList(Frame) = .empty;
        defer frames.deinit(gpa);
        order.clearRetainingCapacity();
        try visited.put(gpa, body, {});
        try frames.append(gpa, .{ .segment = body, .next = 0 });
        while (frames.items.len != 0) {
            const top = &frames.items[frames.items.len - 1];
            const out_edges = edges.get(top.segment).?.items;
            if (top.next < out_edges.len) {
                const child = out_edges[top.next];
                top.next += 1;
                if ((try visited.getOrPut(gpa, child)).found_existing) continue;
                try frames.append(gpa, .{ .segment = child, .next = 0 });
                continue;
            }
            try order.append(gpa, top.segment);
            frames.items.len -= 1;
        }
        std.mem.reverse(LIR.CFStmtId, order.items);

        var position: std.AutoHashMapUnmanaged(LIR.CFStmtId, usize) = .empty;
        defer position.deinit(gpa);
        for (order.items, 0..) |segment, i| try position.put(gpa, segment, i);
        var preds: std.AutoHashMapUnmanaged(LIR.CFStmtId, std.ArrayList(LIR.CFStmtId)) = .empty;
        defer {
            var lists = preds.valueIterator();
            while (lists.next()) |list| list.deinit(gpa);
            preds.deinit(gpa);
        }
        for (edges.keys(), edges.values()) |from, targets| {
            for (targets.items) |to| {
                const entry = try preds.getOrPut(gpa, to);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(gpa, from);
            }
        }
        for (edges.keys(), edges.values()) |from, targets| {
            for (targets.items) |header| {
                if (position.get(header).? > position.get(from).?) continue;
                if (header == body) return self.refuse("loop back to the procedure entry", .{});
                const entry = try loops.getOrPut(gpa, header);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                const members = entry.value_ptr;
                try members.put(gpa, header, {});
                stack.clearRetainingCapacity();
                try stack.append(gpa, from);
                while (stack.pop()) |member| {
                    if ((try members.getOrPut(gpa, member)).found_existing) continue;
                    if (preds.get(member)) |list| try stack.appendSlice(gpa, list.items);
                }
            }
        }
        for (loops.keys(), loops.values()) |header, *members| {
            var it = members.keyIterator();
            while (it.next()) |member| {
                if (member.* == header) continue;
                for (preds.get(member.*).?.items) |pred| {
                    if (!members.contains(pred)) return self.refuse("loop entered other than through its header", .{});
                }
            }
        }
    }

    /// Liveness successors: a join runs its remainder, and its body is
    /// entered only through jumps (whose join params were set beforehand).
    fn pushLiveSuccessors(self: *Emitter, stack: *std.ArrayList(LIR.CFStmtId), stmt: LIR.CFStmt) Allocator.Error!void {
        if (stmt == .join) return stack.append(self.gpa, stmt.join.remainder);
        if (stmt == .jump) {
            if (self.join_bodies.get(stmt.jump.target)) |join_body| try stack.append(self.gpa, join_body);
            return;
        }
        return self.pushSuccessors(stack, stmt);
    }

    /// Give each LIR local of the current procedure a Lua slot, sharing a
    /// slot among locals whose live ranges never overlap: backward liveness
    /// over the statement graph, an interference graph (each definition
    /// against everything live after it and the statement's other operands)
    /// and greedy graph coloring, parameters first. Frame size decides
    /// whether hot code compiles: LuaJIT traces abort past 250 stack slots
    /// across inlined frames ("trace too deep"). Returns the slot count.
    fn assignSlots(self: *Emitter, args: anytype, body: LIR.CFStmtId) EmitError!usize {
        const gpa = self.gpa;
        self.slot_of.clearRetainingCapacity();

        var stmts: std.AutoArrayHashMapUnmanaged(LIR.CFStmtId, void) = .empty;
        defer stmts.deinit(gpa);
        var locals: std.AutoArrayHashMapUnmanaged(LIR.LocalId, void) = .empty;
        defer locals.deinit(gpa);
        for (0..args.len) |i| try locals.put(gpa, GuardedList.at(args, i), {});

        var work: std.ArrayList(LIR.CFStmtId) = .empty;
        defer work.deinit(gpa);
        try work.append(gpa, body);
        while (work.pop()) |id| {
            if ((try stmts.getOrPut(gpa, id)).found_existing) continue;
            try self.pushLiveSuccessors(&work, self.store().getCFStmt(id));
        }
        const n = stmts.count();

        // Per statement: dense local indices read and defined, and dense
        // successor indices, as flat lists with n + 1 offsets each.
        const Collect = struct {
            gpa: Allocator,
            locals: *std.AutoArrayHashMapUnmanaged(LIR.LocalId, void),
            list: *std.ArrayList(u32),
            err: ?Allocator.Error = null,
            fn note(ctx: *@This(), local: LIR.LocalId) void {
                if (ctx.err != null) return;
                const entry = ctx.locals.getOrPut(ctx.gpa, local) catch |err| {
                    ctx.err = err;
                    return;
                };
                ctx.list.append(ctx.gpa, @intCast(entry.index)) catch |err| {
                    ctx.err = err;
                };
            }
        };
        var reads: std.ArrayList(u32) = .empty;
        defer reads.deinit(gpa);
        var defs: std.ArrayList(u32) = .empty;
        defer defs.deinit(gpa);
        var succs: std.ArrayList(u32) = .empty;
        defer succs.deinit(gpa);
        const read_off = try gpa.alloc(u32, n + 1);
        defer gpa.free(read_off);
        const def_off = try gpa.alloc(u32, n + 1);
        defer gpa.free(def_off);
        const succ_off = try gpa.alloc(u32, n + 1);
        defer gpa.free(succ_off);
        for (stmts.keys(), 0..) |id, i| {
            const stmt = self.store().getCFStmt(id);
            read_off[i] = @intCast(reads.items.len);
            def_off[i] = @intCast(defs.items.len);
            succ_off[i] = @intCast(succs.items.len);
            var read_ctx = Collect{ .gpa = gpa, .locals = &locals, .list = &reads };
            lir.BodyClone.forEachStmtRead(self.store(), stmt, &read_ctx, Collect.note);
            if (read_ctx.err) |err| return err;
            // A join's params are written by the `set_local`s before its jumps.
            if (stmt != .join) {
                var def_ctx = Collect{ .gpa = gpa, .locals = &locals, .list = &defs };
                lir.BodyClone.forEachStmtDef(self.store(), stmt, &def_ctx, Collect.note);
                if (def_ctx.err) |err| return err;
            }
            work.clearRetainingCapacity();
            try self.pushLiveSuccessors(&work, stmt);
            for (work.items) |next| try succs.append(gpa, @intCast(stmts.getIndex(next).?));
        }
        read_off[n] = @intCast(reads.items.len);
        def_off[n] = @intCast(defs.items.len);
        succ_off[n] = @intCast(succs.items.len);

        const nl = locals.count();
        const words = (nl + 63) / 64;
        const live_in = try gpa.alloc(u64, n * words);
        defer gpa.free(live_in);
        @memset(live_in, 0);
        const live_out = try gpa.alloc(u64, words);
        defer gpa.free(live_out);
        const scratch = try gpa.alloc(u64, words);
        defer gpa.free(scratch);
        const Bits = struct {
            fn set(row: []u64, bit: usize) void {
                row[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
            }
            fn get(row: []const u64, bit: usize) bool {
                return row[bit / 64] & (@as(u64, 1) << @intCast(bit % 64)) != 0;
            }
            fn clear(row: []u64, bit: usize) void {
                row[bit / 64] &= ~(@as(u64, 1) << @intCast(bit % 64));
            }
        };
        const liveOut = struct {
            fn f(out: []u64, in: []const u64, list: []const u32, width: usize) void {
                @memset(out, 0);
                for (list) |s| {
                    for (out, in[s * width ..][0..width]) |*o, x| o.* |= x;
                }
            }
        }.f;

        // Backward liveness to a fixed point: in = reads + (out - defs).
        var changed = true;
        while (changed) {
            changed = false;
            var i = n;
            while (i > 0) {
                i -= 1;
                liveOut(live_out, live_in, succs.items[succ_off[i]..succ_off[i + 1]], words);
                for (defs.items[def_off[i]..def_off[i + 1]]) |d| Bits.clear(live_out, d);
                for (reads.items[read_off[i]..read_off[i + 1]]) |r| Bits.set(live_out, r);
                const in = live_in[i * words ..][0..words];
                if (!std.mem.eql(u64, in, live_out)) {
                    @memcpy(in, live_out);
                    changed = true;
                }
            }
        }

        // Interference: a definition conflicts with every local live after
        // its statement and with the statement's other operands (the
        // statement may write its target before it has read them all).
        const graph = try gpa.alloc(u64, nl * words);
        defer gpa.free(graph);
        @memset(graph, 0);
        const conflict = struct {
            fn f(g: []u64, width: usize, a: usize, b: usize) void {
                if (a == b) return;
                Bits.set(g[a * width ..][0..width], b);
                Bits.set(g[b * width ..][0..width], a);
            }
        }.f;
        for (0..n) |i| {
            const stmt_defs = defs.items[def_off[i]..def_off[i + 1]];
            if (stmt_defs.len == 0) continue;
            liveOut(live_out, live_in, succs.items[succ_off[i]..succ_off[i + 1]], words);
            for (stmt_defs) |d| {
                for (reads.items[read_off[i]..read_off[i + 1]]) |r| conflict(graph, words, d, r);
                for (stmt_defs) |other| conflict(graph, words, d, other);
                for (live_out, 0..) |word, wi| {
                    var bits = word;
                    while (bits != 0) : (bits &= bits - 1) conflict(graph, words, d, wi * 64 + @ctz(bits));
                }
            }
        }
        // Parameters are all defined on entry, alongside anything live there.
        @memcpy(scratch, live_in[0..words]);
        for (0..args.len) |a| Bits.set(scratch, a);
        for (0..args.len) |a| {
            for (scratch, 0..) |word, wi| {
                var bits = word;
                while (bits != 0) : (bits &= bits - 1) conflict(graph, words, a, wi * 64 + @ctz(bits));
            }
        }

        // Greedy coloring in index order (parameters take slots 0..). A
        // flattened local takes one color per leaf.
        self.leaf_slots_of.clearRetainingCapacity();
        self.leaf_slot_pool.clearRetainingCapacity();
        const first_color = try gpa.alloc(u32, nl);
        defer gpa.free(first_color);
        const width = try gpa.alloc(u32, nl);
        defer gpa.free(width);
        var total_width: usize = 0;
        for (locals.keys(), 0..) |local, l| {
            width[l] = if (try self.shapeOf(self.layoutOfLocal(local))) |shape| self.shape_nodes.items[shape].leaf_count else 1;
            total_width += width[l];
        }
        var pool: std.ArrayList(u32) = .empty;
        defer pool.deinit(gpa);
        var taken = try std.DynamicBitSetUnmanaged.initEmpty(gpa, total_width + 1);
        defer taken.deinit(gpa);
        var slots: usize = 0;
        for (0..nl) |l| {
            taken.unsetAll();
            const row = graph[l * words ..][0..words];
            for (0..l) |j| {
                if (Bits.get(row, j)) {
                    for (pool.items[first_color[j]..][0..width[j]]) |c| taken.set(c);
                }
            }
            first_color[l] = @intCast(pool.items.len);
            var c: u32 = 0;
            for (0..width[l]) |_| {
                while (taken.isSet(c)) c += 1;
                try pool.append(gpa, c);
                taken.set(c);
                slots = @max(slots, c + 1);
            }
            const local = locals.keys()[l];
            if ((try self.shapeOf(self.layoutOfLocal(local))) != null) {
                try self.leaf_slots_of.put(gpa, local, .{ .first = @intCast(self.leaf_slot_pool.items.len), .count = width[l] });
                try self.leaf_slot_pool.appendSlice(gpa, pool.items[first_color[l]..][0..width[l]]);
            } else {
                try self.slot_of.put(gpa, local, pool.items[first_color[l]]);
            }
        }
        return slots;
    }

    fn emitLocal(self: *Emitter, local: LIR.LocalId) EmitError!void {
        if (self.str_operands and self.reprOfLocal(local) == .str) return self.emitStrOperand(local);
        return self.emitSlot(local);
    }

    fn emitSlot(self: *Emitter, local: LIR.LocalId) EmitError!void {
        if (self.localShape(local)) |shape| return self.emitMaterialize(shape, self.leafSlots(local).?);
        const slot = self.slot_of.get(local) orelse return self.refuse("local {d} outside every statement", .{@intFromEnum(local)});
        try self.emitSlotName(slot);
    }

    /// A flattened local's leaves as a comma-separated Lua expression list.
    fn emitLeafList(self: *Emitter, slots: []const u32) EmitError!void {
        for (slots, 0..) |slot, i| {
            if (i != 0) try self.w().writeAll(", ");
            try self.emitSlotName(slot);
        }
    }
    /// The leaf shape of a struct or tag-union layout, or null when values
    /// of the layout stay Lua tables (other layouts, or more than
    /// `max_flat_leaves` leaves). Structs flatten by original field index and
    /// tag unions into a discriminant leaf followed by each variant's payload
    /// shape; zero-sized parts take no leaf. Leaves are numbered depth-first,
    /// so every subtree's leaves form a contiguous range. Cached per layout.
    fn shapeOf(self: *Emitter, idx: layout.Idx) EmitError!?u32 {
        if (self.shapes.get(idx)) |cached| return cached;
        if (!aggregateLayout(self, idx)) {
            try self.shapes.put(self.gpa, idx, null);
            return null;
        }
        const nodes_before = self.shape_nodes.items.len;
        const children_before = self.shape_children.items.len;
        var leaves: u32 = 0;
        const root = try self.buildShape(idx, &leaves);
        if (root == null) {
            self.shape_nodes.items.len = nodes_before;
            self.shape_children.items.len = children_before;
        }
        try self.shapes.put(self.gpa, idx, root);
        return root;
    }

    fn aggregateLayout(self: *Emitter, idx: layout.Idx) bool {
        if (reprOf(idx) != .other or isVectorLayout(idx)) return false;
        return switch (self.layoutTag(idx)) {
            .struct_, .tag_union => true,
            .scalar, .box, .box_of_zst, .erased_box, .list, .list_of_zst, .closure, .erased_callable, .zst, .ptr => false,
        };
    }

    fn buildShape(self: *Emitter, idx: layout.Idx, leaves: *u32) EmitError!?u32 {
        const gpa = self.gpa;
        if (!aggregateLayout(self, idx)) {
            if (self.layoutTag(idx) == .zst) return try self.addShapeNode(.{ .kind = .zst, .layout = idx });
            if (leaves.* >= max_flat_leaves) return null;
            leaves.* += 1;
            return try self.addShapeNode(.{ .kind = .leaf, .layout = idx, .leaf_first = leaves.* - 1, .leaf_count = 1 });
        }
        var kids: std.ArrayList(u32) = .empty;
        defer kids.deinit(gpa);
        const first_leaf = leaves.*;
        var kind: ShapeKind = .struct_;
        switch (self.layoutTag(idx)) {
            .struct_ => {
                const sidx = self.layouts().getLayout(idx).getStruct().idx;
                const count = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields()).len;
                for (0..count) |i| {
                    if (self.layouts().getStructFieldSizeByOriginalIndex(sidx, @intCast(i)) == 0) {
                        try kids.append(gpa, try self.addShapeNode(.{ .kind = .zst, .layout = .zst }));
                    } else {
                        try kids.append(gpa, try self.buildShape(self.layouts().getStructFieldLayoutByOriginalIndex(sidx, @intCast(i)), leaves) orelse return null);
                    }
                }
            },
            .tag_union => {
                kind = .tag;
                if (leaves.* >= max_flat_leaves) return null;
                leaves.* += 1; // the discriminant
                // Only one variant is live, so every payload starts at the
                // same leaf: a tag takes 1 + its largest payload's leaves.
                const base = leaves.*;
                var end_leaf = base;
                const tu = self.layouts().getLayout(idx).getTagUnion();
                const variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(tu.idx));
                for (0..variants.len) |v| {
                    leaves.* = base;
                    const payload = variants.get(v).payload_layout;
                    if (self.layoutWidth(payload) == 0) {
                        try kids.append(gpa, try self.addShapeNode(.{ .kind = .zst, .layout = .zst }));
                    } else {
                        try kids.append(gpa, try self.buildShape(payload, leaves) orelse return null);
                    }
                    end_leaf = @max(end_leaf, leaves.*);
                }
                leaves.* = end_leaf;
            },
            .scalar, .box, .box_of_zst, .erased_box, .list, .list_of_zst, .closure, .erased_callable, .zst, .ptr => unreachable,
        }
        const child_first: u32 = @intCast(self.shape_children.items.len);
        try self.shape_children.appendSlice(gpa, kids.items);
        return try self.addShapeNode(.{
            .kind = kind,
            .layout = idx,
            .leaf_first = first_leaf,
            .leaf_count = leaves.* - first_leaf,
            .child_first = child_first,
            .child_count = @intCast(kids.items.len),
        });
    }

    fn addShapeNode(self: *Emitter, node: ShapeNode) EmitError!u32 {
        try self.shape_nodes.append(self.gpa, node);
        return @intCast(self.shape_nodes.items.len - 1);
    }

    fn shapeChild(self: *Emitter, node: u32, i: usize) u32 {
        return self.shape_children.items[self.shape_nodes.items[node].child_first + i];
    }

    /// Leaf slots of a flattened local, or null for a table-valued local.
    fn leafSlots(self: *Emitter, local: LIR.LocalId) ?[]const u32 {
        const at = self.leaf_slots_of.get(local) orelse return null;
        return self.leaf_slot_pool.items[at.first..][0..at.count];
    }

    fn localShape(self: *Emitter, local: LIR.LocalId) ?u32 {
        if (self.leaf_slots_of.get(local) == null) return null;
        return self.shapes.get(self.layoutOfLocal(local)).?.?;
    }

    fn emitSlotName(self: *Emitter, slot: u32) EmitError!void {
        if (slot >= max_frame_locals) return self.w().print("S[{d}]", .{slot - max_frame_locals + 1});
        try self.w().print("r{d}", .{slot});
    }

    /// The table a shape's leaves stand for (`slots` are the root's leaves):
    /// a leaf itself, or a call to the layout's materializer, so a site costs
    /// one call however many variants the layout has (LuaJIT rejects a
    /// function whose jumps span more than 32,767 instructions).
    fn emitMaterialize(self: *Emitter, node: u32, slots: []const u32) EmitError!void {
        const n = self.shape_nodes.items[node];
        switch (n.kind) {
            .leaf => try self.emitSlotName(slots[n.leaf_first]),
            .zst => try self.w().writeAll("rt.ZST"),
            .struct_, .tag => {
                try self.materializers.put(self.gpa, n.layout, node);
                try self.w().print("R.m{d}(", .{@intFromEnum(n.layout)});
                for (0..n.leaf_count) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    try self.emitSlotName(slots[n.leaf_first + i]);
                }
                try self.w().writeAll(")");
            },
        }
    }

    /// Load a shape's leaves from the table at the Lua expression `path`: a
    /// leaf directly, an aggregate through the layout's unpacker.
    fn emitUnpack(self: *Emitter, node: u32, slots: []const u32, path: []const u8, depth: usize) EmitError!void {
        const n = self.shape_nodes.items[node];
        switch (n.kind) {
            .zst => {},
            .leaf => {
                try self.indent(depth);
                try self.emitSlotName(slots[n.leaf_first]);
                try self.w().print(" = {s}\n", .{path});
            },
            .struct_, .tag => {
                if (n.leaf_count == 0) return;
                try self.unpackers.put(self.gpa, n.layout, node);
                try self.indent(depth);
                for (0..n.leaf_count) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    try self.emitSlotName(slots[n.leaf_first + i]);
                }
                try self.w().print(" = R.u{d}({s})\n", .{ @intFromEnum(n.layout), path });
            },
        }
    }

    /// A shape node's value inside a materializer, over its leaves `l1..lN`
    /// (numbered from the materialized node's first leaf, `base`).
    fn emitShapeExpr(self: *Emitter, node: u32, base: u32) EmitError!void {
        const n = self.shape_nodes.items[node];
        switch (n.kind) {
            .leaf => try self.w().print("l{d}", .{n.leaf_first - base + 1}),
            .zst => try self.w().writeAll("rt.ZST"),
            .struct_, .tag => {
                try self.materializers.put(self.gpa, n.layout, node);
                try self.w().print("R.m{d}(", .{@intFromEnum(n.layout)});
                for (0..n.leaf_count) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    try self.w().print("l{d}", .{n.leaf_first - base + 1 + i});
                }
                try self.w().writeAll(")");
            },
        }
    }

    /// Inside an unpacker: load child `node`'s leaves (`x<k>`, numbered from
    /// the unpacked node's first leaf, `base`) from the table field `field`.
    fn emitShapeLoad(self: *Emitter, node: u32, base: u32, field: []const u8, declare: bool, depth: usize) EmitError!void {
        const n = self.shape_nodes.items[node];
        if (n.kind == .zst or n.leaf_count == 0) return;
        try self.indent(depth);
        if (declare) try self.w().writeAll("local ");
        for (0..n.leaf_count) |i| {
            if (i != 0) try self.w().writeAll(", ");
            try self.w().print("x{d}", .{n.leaf_first - base + 1 + i});
        }
        if (n.kind == .leaf) return self.w().print(" = {s}\n", .{field});
        try self.unpackers.put(self.gpa, n.layout, node);
        try self.w().print(" = R.u{d}({s})\n", .{ @intFromEnum(n.layout), field });
    }

    /// Define every materializer and unpacker the code calls, one level of
    /// the shape each (nested aggregates call their own layout's helper).
    /// Structs index children by semantic field index + 1; a tag is
    /// { discriminant, payload }, the payload of the active variant.
    fn emitShapeHelpers(self: *Emitter) EmitError!void {
        var i: usize = 0;
        while (i < self.materializers.count()) : (i += 1) {
            const node = self.materializers.values()[i];
            const n = self.shape_nodes.items[node];
            try self.w().print("R.m{d} = function(", .{@intFromEnum(n.layout)});
            for (0..n.leaf_count) |k| try self.w().print("{s}l{d}", .{ if (k == 0) "" else ", ", k + 1 });
            try self.w().writeAll(")\n\treturn ");
            if (n.kind == .struct_) {
                try self.w().writeAll("{");
                for (0..n.child_count) |c| {
                    if (c != 0) try self.w().writeAll(", ");
                    try self.emitShapeExpr(self.shapeChild(node, c), n.leaf_first);
                }
                try self.w().writeAll("}");
            } else {
                // Tables are truthy, so `and`/`or` selects the active variant.
                for (0..n.child_count) |v| {
                    if (v + 1 < n.child_count) try self.w().print("l1 == {d} and ", .{v});
                    try self.w().writeAll("{l1, ");
                    try self.emitShapeExpr(self.shapeChild(node, v), n.leaf_first);
                    try self.w().writeAll("}");
                    if (v + 1 < n.child_count) try self.w().writeAll(" or ");
                }
            }
            try self.w().writeAll("\nend\n");
        }
        i = 0;
        while (i < self.unpackers.count()) : (i += 1) {
            const node = self.unpackers.values()[i];
            const n = self.shape_nodes.items[node];
            try self.w().print("R.u{d} = function(t)\n", .{@intFromEnum(n.layout)});
            if (n.kind == .struct_) {
                for (0..n.child_count) |c| {
                    const field = try std.fmt.allocPrint(self.gpa, "t[{d}]", .{c + 1});
                    defer self.gpa.free(field);
                    try self.emitShapeLoad(self.shapeChild(node, c), n.leaf_first, field, true, 1);
                }
            } else {
                try self.w().writeAll("\tlocal x1 = t[1]\n");
                if (n.leaf_count > 1) {
                    try self.w().writeAll("\tlocal ");
                    for (1..n.leaf_count) |k| try self.w().print("{s}x{d}", .{ if (k == 1) "" else ", ", k + 1 });
                    try self.w().writeAll("\n");
                }
                var first = true;
                for (0..n.child_count) |v| {
                    const child = self.shapeChild(node, v);
                    if (self.shape_nodes.items[child].leaf_count == 0) continue;
                    try self.w().print("\t{s} x1 == {d} then\n", .{ if (first) "if" else "elseif", v });
                    try self.emitShapeLoad(child, n.leaf_first, "t[2]", false, 2);
                    first = false;
                }
                if (!first) try self.w().writeAll("\tend\n");
            }
            try self.w().writeAll("\treturn ");
            for (0..n.leaf_count) |k| try self.w().print("{s}x{d}", .{ if (k == 0) "" else ", ", k + 1 });
            try self.w().writeAll("\nend\n");
        }
    }

    /// Whether two shapes store the same leaves in the same places (same
    /// structure, and leaves on the same side of boxing).
    fn sameShape(self: *Emitter, a: u32, b: u32) bool {
        const na = self.shape_nodes.items[a];
        const nb = self.shape_nodes.items[b];
        if (na.kind != nb.kind or na.child_count != nb.child_count or na.leaf_count != nb.leaf_count) return false;
        if (na.kind == .leaf) return self.isBoxLayout(na.layout) == self.isBoxLayout(nb.layout) and reprOf(na.layout) == reprOf(nb.layout);
        for (0..na.child_count) |i| {
            if (!self.sameShape(self.shapeChild(a, i), self.shapeChild(b, i))) return false;
        }
        return true;
    }

    /// `dst = src` leaf by leaf, as one parallel assignment.
    fn emitCopyLeaves(self: *Emitter, dst: []const u32, src: []const u32, depth: usize) EmitError!void {
        if (dst.len == 0 or std.mem.eql(u32, dst, src)) return;
        try self.indent(depth);
        for (dst, 0..) |slot, i| {
            if (i != 0) try self.w().writeAll(", ");
            try self.emitSlotName(slot);
        }
        try self.w().writeAll(" = ");
        for (src, 0..) |slot, i| {
            if (i != 0) try self.w().writeAll(", ");
            try self.emitSlotName(slot);
        }
        try self.w().writeAll("\n");
    }

    /// Fill shape `node` (leaves `slots`, layout `expected`) from `source`.
    fn emitFillFromLocal(self: *Emitter, node: u32, slots: []const u32, expected: layout.Idx, source: LIR.LocalId, depth: usize) EmitError!void {
        const n = self.shape_nodes.items[node];
        if (self.localShape(source)) |src_shape| {
            if (self.sameShape(node, src_shape)) {
                return self.emitCopyLeaves(slots[n.leaf_first..][0..n.leaf_count], self.leafSlots(source).?, depth);
            }
        }
        switch (n.kind) {
            .zst => {},
            .leaf => {
                try self.indent(depth);
                try self.emitSlotName(slots[n.leaf_first]);
                try self.w().writeAll(" = ");
                try self.emitCoerced(source, expected);
                try self.w().writeAll("\n");
            },
            .struct_, .tag => {
                try self.indent(depth);
                try self.w().writeAll("rS = ");
                try self.emitCoerced(source, expected);
                try self.w().writeAll("\n");
                try self.emitUnpack(node, slots, "rS", depth);
            },
        }
    }

    /// `target = <the value of shape node over slots>`, flattened or not.
    fn emitAssignFromShape(self: *Emitter, target: LIR.LocalId, node: u32, slots: []const u32, depth: usize) EmitError!void {
        const n = self.shape_nodes.items[node];
        if (self.localShape(target)) |dst_shape| {
            const dst = self.leafSlots(target).?;
            if (self.sameShape(dst_shape, node)) return self.emitCopyLeaves(dst, slots[n.leaf_first..][0..n.leaf_count], depth);
            try self.indent(depth);
            try self.w().writeAll("rS = ");
            try self.emitMaterialize(node, slots);
            try self.w().writeAll("\n");
            return self.emitUnpack(dst_shape, dst, "rS", depth);
        }
        try self.beginAssign(target, depth);
        try self.emitMaterialize(node, slots);
        try self.w().writeAll("\n");
    }

    /// `assign_ref` involving a flattened local: projections of a flattened
    /// source read its leaves, and copies into a flattened target fill its
    /// leaves. False when neither side is flattened.
    fn emitFlatRef(self: *Emitter, target: LIR.LocalId, op: LIR.RefOp, depth: usize) EmitError!bool {
        const target_layout = self.layoutOfLocal(target);
        switch (op) {
            .local => |source| {
                const shape = self.localShape(target) orelse return false;
                try self.emitFillFromLocal(shape, self.leafSlots(target).?, target_layout, source, depth);
            },
            .nominal => |r| {
                const shape = self.localShape(target) orelse return false;
                try self.emitFillFromLocal(shape, self.leafSlots(target).?, target_layout, r.backing_ref, depth);
            },
            .list_reinterpret => return false,
            .field => |f| {
                const shape = self.localShape(f.source) orelse return false;
                try self.emitAssignFromShape(target, self.shapeChild(shape, f.field_idx), self.leafSlots(f.source).?, depth);
            },
            .discriminant => |d| {
                const shape = self.localShape(d.source) orelse return false;
                try self.beginAssign(target, depth);
                try self.emitSlotName(self.leafSlots(d.source).?[self.shape_nodes.items[shape].leaf_first]);
                try self.w().writeAll("\n");
            },
            .tag_payload => |p| {
                const shape = self.localShape(p.source) orelse return false;
                const variant = self.shapeChild(shape, p.variant_index);
                const payload_layout = self.tagVariantPayloadLayout(self.layoutOfLocal(p.source), p.variant_index);
                const sub = if (self.shape_nodes.items[variant].kind == .struct_ and self.layoutTag(payload_layout) == .struct_)
                    self.shapeChild(variant, p.payload_idx)
                else
                    variant;
                try self.emitAssignFromShape(target, sub, self.leafSlots(p.source).?, depth);
            },
            .tag_payload_struct => |p| {
                const shape = self.localShape(p.source) orelse return false;
                try self.emitAssignFromShape(target, self.shapeChild(shape, p.variant_index), self.leafSlots(p.source).?, depth);
            },
        }
        return true;
    }

    /// A Str operand of an operation that takes plain Lua strings.
    fn emitStrOperand(self: *Emitter, local: LIR.LocalId) EmitError!void {
        try self.w().writeAll("rt.str(");
        try self.emitSlot(local);
        try self.w().writeAll(")");
    }

    /// An argument to a hosted procedure: hosts read Str values, at any
    /// depth, as Lua strings.
    fn emitHostedArg(self: *Emitter, local: LIR.LocalId) EmitError!void {
        const idx = self.layoutOfLocal(local);
        if (reprOf(idx) == .str) return self.emitStrOperand(local);
        var visiting: std.AutoHashMapUnmanaged(layout.Idx, void) = .empty;
        defer visiting.deinit(self.gpa);
        if (!try self.layoutHasStr(idx, &visiting)) return self.emitSlot(local);
        try self.w().writeAll("rt.str_deep(");
        try self.emitSlot(local);
        try self.w().writeAll(")");
    }

    /// Whether values of this layout can hold a Str (directly, in fields,
    /// tag payloads, list elements or boxes).
    fn layoutHasStr(self: *Emitter, idx: layout.Idx, visiting: *std.AutoHashMapUnmanaged(layout.Idx, void)) EmitError!bool {
        if (reprOf(idx) == .str) return true;
        if ((try visiting.getOrPut(self.gpa, idx)).found_existing) return false;
        const lay = self.layouts().getLayout(idx);
        switch (lay.tag) {
            .scalar, .zst, .box_of_zst, .list_of_zst, .ptr => return false,
            .box, .list => return self.layoutHasStr(lay.getIdx(), visiting),
            .struct_ => {
                const fields = self.layouts().getStructInfo(lay).fields;
                for (0..fields.len) |i| {
                    if (try self.layoutHasStr(fields.get(i).layout, visiting)) return true;
                }
                return false;
            },
            .tag_union => {
                const variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(lay.getTagUnion().idx));
                for (0..variants.len) |i| {
                    if (try self.layoutHasStr(variants.get(i).payload_layout, visiting)) return true;
                }
                return false;
            },
            // Captures are opaque to the host, which calls them, never reads them.
            .closure, .erased_callable, .erased_box => return false,
        }
    }

    fn reprOfLocal(self: *Emitter, local: LIR.LocalId) Repr {
        return reprOf(self.store().getLocal(local).layout_idx);
    }

    fn indent(self: *Emitter, depth: usize) EmitError!void {
        for (0..depth) |_| try self.w().writeAll("\t");
    }

    fn beginAssign(self: *Emitter, target: LIR.LocalId, depth: usize) EmitError!void {
        try self.indent(depth);
        if (self.leafSlots(target) != null) {
            // A whole value from a table producer: through the scratch,
            // then into the leaves before the next statement.
            self.pending_unpack = target;
            return self.w().writeAll("rS = ");
        }
        try self.emitLocal(target);
        try self.w().writeAll(" = ");
    }

    /// Emit a statement chain until a terminal statement. Joins emit their
    /// remainder, then a label, then their body; jumps become `goto`.
    fn emitChain(self: *Emitter, first: LIR.CFStmtId, depth: usize, segment_entry: bool) EmitError!void {
        var current = first;
        while (true) {
            if (self.pending_unpack) |target| {
                self.pending_unpack = null;
                try self.emitUnpack(self.localShape(target).?, self.leafSlots(target).?, "rS", depth);
            }
            if (!(segment_entry and current == first) and self.shared.contains(current)) {
                // A shared continuation: emitted once as a top-level segment.
                try self.indent(depth);
                try self.w().print("goto s{d}\n", .{@intFromEnum(current)});
                try self.segment_queue.append(self.gpa, current);
                return;
            }
            if ((try self.visited.getOrPut(self.gpa, current)).found_existing) {
                return self.refuse("shared statement continuation", .{});
            }
            const stmt = self.store().getCFStmt(current);
            switch (stmt) {
                .init_uninitialized => |s| current = s.next,
                .assign_ref => |s| {
                    try self.emitAssignRef(s.target, s.op, depth);
                    current = s.next;
                },
                .assign_literal => |s| {
                    if (s.fresh_alternative != null) return self.refuse("literal with fresh alternative", .{});
                    try self.beginAssign(s.target, depth);
                    try self.emitLiteral(s.value, s.target);
                    try self.w().writeAll("\n");
                    current = s.next;
                },
                .assign_call => |s| {
                    if (s.result_desc != null or s.out_desc != null) return self.refuse("descriptor-carrying call", .{});
                    if (self.store().getProcSpec(s.proc).hosted != null and self.input.entrypoints.len == 0) return self.refuse("hosted procedure call", .{});
                    if (self.flat_abi.contains(s.proc)) {
                        try self.emitFlatCall(s.target, s.proc, s.args, depth);
                        current = s.next;
                        continue;
                    }
                    try self.beginAssign(s.target, depth);
                    try self.w().print("P[{d}](", .{@intFromEnum(s.proc)});
                    if (self.store().getProcSpec(s.proc).hosted != null) {
                        const call_args = self.store().getLocalSpan(s.args);
                        for (0..call_args.len) |i| {
                            if (i != 0) try self.w().writeAll(", ");
                            try self.emitHostedArg(GuardedList.at(call_args, i));
                        }
                    } else {
                        try self.emitArgs(s.args);
                    }
                    try self.w().writeAll(")\n");
                    current = s.next;
                },
                .assign_low_level => |s| {
                    if (try self.emitListLowLevel(s, depth)) {
                        current = s.next;
                        continue;
                    }
                    if (try self.emitSimdLowLevel(s, depth)) {
                        current = s.next;
                        continue;
                    }
                    if (try self.emitInlineCheckedArith(s, depth)) {
                        current = s.next;
                        continue;
                    }
                    if (try self.emitHasherIntoLeaf(s, depth)) {
                        current = s.next;
                        continue;
                    }
                    try self.beginAssign(s.target, depth);
                    try self.emitLowLevel(s.op, s.args, s.target);
                    try self.w().writeAll("\n");
                    current = s.next;
                },
                .assign_struct => |s| {
                    if (s.contents_desc != null) return self.refuse("descriptor-carrying struct", .{});
                    try self.emitAssignStruct(s.target, s.fields, depth);
                    current = s.next;
                },
                .assign_list => |s| {
                    try self.emitAssignList(s.target, s.elems, depth);
                    current = s.next;
                },
                .assign_tag => |s| {
                    try self.emitAssignTag(s, depth);
                    current = s.next;
                },
                .set_local => |s| {
                    if (self.localShape(s.target)) |shape| {
                        try self.emitFillFromLocal(shape, self.leafSlots(s.target).?, self.layoutOfLocal(s.target), s.value, depth);
                        current = s.next;
                        continue;
                    }
                    try self.beginAssign(s.target, depth);
                    try self.emitLocal(s.value);
                    try self.w().writeAll("\n");
                    current = s.next;
                },
                .incref => |s| {
                    try self.emitRc("incref", s.value, s.rc, s.count, depth);
                    current = s.next;
                },
                .decref => |s| {
                    try self.emitRc("decref", s.value, s.rc, 1, depth);
                    current = s.next;
                },
                .free => |s| {
                    try self.emitRc("free", s.value, s.rc, 1, depth);
                    current = s.next;
                },
                .decref_if_initialized => |s| {
                    // `cond` is the compiler-produced presence proof for `value`.
                    try self.indent(depth);
                    try self.w().writeAll("if ");
                    try self.emitPresence(s.cond, s.cond_mask);
                    try self.w().writeAll(" then\n");
                    try self.emitRc("decref", s.value, s.rc, 1, depth + 1);
                    try self.indent(depth);
                    try self.w().writeAll("end\n");
                    current = s.next;
                },
                .switch_stmt => |s| return self.emitSwitch(s, depth),
                .switch_initialized_payload => |s| {
                    try self.indent(depth);
                    try self.w().writeAll("if ");
                    try self.emitPresence(s.cond, s.cond_mask);
                    try self.w().writeAll(" then\n");
                    try self.emitChain(s.initialized_branch, depth + 1, false);
                    try self.indent(depth);
                    try self.w().writeAll("else\n");
                    try self.emitChain(s.uninitialized_branch, depth + 1, false);
                    try self.indent(depth);
                    return self.w().writeAll("end\n");
                },
                .join => |s| {
                    // The body is a top-level segment entered only by jumps.
                    // Retained units have no runtime ABI, and maybe-uninitialized
                    // params are released only through their explicit
                    // `decref_if_initialized` statements, so neither needs code here.
                    try self.emitChain(s.remainder, depth, false);
                    try self.segment_queue.append(self.gpa, s.body);
                    return;
                },
                .jump => |s| {
                    try self.indent(depth);
                    const target_body = self.join_bodies.get(s.target) orelse return self.refuse("jump to unknown join {d}", .{@intFromEnum(s.target)});
                    try self.w().print("goto s{d}\n", .{@intFromEnum(target_body)});
                    return;
                },
                .ret => |s| {
                    try self.indent(depth);
                    try self.w().print("DEPTH = DEPTH - {d} do return ", .{self.frame_slots});
                    if (self.current_flat_abi) {
                        if (try self.shapeOf(self.current_ret_layout)) |ret_shape| {
                            const value_shape = self.localShape(s.value) orelse return self.refuse("flattened return of a table value", .{});
                            if (!self.sameShape(ret_shape, value_shape)) return self.refuse("flattened return shape mismatch", .{});
                            try self.emitLeafList(self.leafSlots(s.value).?);
                            try self.w().writeAll(" end\n");
                            return;
                        }
                    }
                    try self.emitLocal(s.value);
                    try self.w().writeAll(" end\n");
                    return;
                },
                // Inline expect (no test-plan site): the host reports "expect
                // failed" (the dev backend's static message) and execution goes on.
                .expect => |s| {
                    if (s.site != null) return self.refuse("test-plan expect", .{});
                    if (self.reprOfLocal(s.condition) != .bool) return self.refuse("expect condition of {s}", .{@tagName(self.reprOfLocal(s.condition))});
                    try self.indent(depth);
                    try self.w().writeAll("if not ");
                    try self.emitLocal(s.condition);
                    try self.w().writeAll(" then rt.expect_failed(\"expect failed\") end\n");
                    current = s.next;
                },
                .debug => |s| {
                    try self.indent(depth);
                    try self.w().writeAll("rt.dbg(");
                    try self.emitStrOperand(s.message);
                    try self.w().writeAll(")\n");
                    current = s.next;
                },
                // A compile-time coverage marker; nothing happens at run time.
                .comptime_branch_taken => |s| current = s.next,
                .runtime_error => {
                    try self.indent(depth);
                    try self.w().writeAll("rt.runtime_error()\n");
                    return;
                },
                .crash => |s| {
                    try self.indent(depth);
                    try self.w().writeAll("rt.crash(");
                    switch (s.msg) {
                        .literal => |idx| try emitLuaString(self.w(), self.store().getString(idx)),
                        .local => |local| try self.emitStrOperand(local),
                    }
                    try self.w().writeAll(")\n");
                    return;
                },
                .assign_packed_erased_fn => |s| {
                    if (s.result_desc != null) return self.refuse("descriptor-carrying erased callable", .{});
                    try self.beginAssign(s.target, depth);
                    try self.w().print("rt.erased_pack(P[{d}], ", .{@intFromEnum(s.proc)});
                    if (s.capture) |capture| try self.emitLocal(capture) else try self.w().writeAll("nil");
                    try self.w().writeAll(", ");
                    switch (s.on_drop) {
                        .none => try self.w().writeAll("nil"),
                        .rc_helper => |key| try self.emitRcChild(key),
                        .boxy_capture, .interpreter_context_drop => return self.refuse("erased callable on_drop {s}", .{@tagName(s.on_drop)}),
                    }
                    try self.w().writeAll(", ");
                    if (s.reuse) |reuse| try self.emitLocal(reuse) else try self.w().writeAll("nil");
                    try self.w().print(", {s})\n", .{if (s.reuse_unique) "true" else "false"});
                    current = s.next;
                },
                .assign_call_erased => |s| {
                    if (s.result_desc != null or s.out_desc != null or s.arg_descs.len != 0) return self.refuse("descriptor-carrying erased call", .{});
                    // c.proc(explicit args..., capture, reuse slot)
                    try self.beginAssign(s.target, depth);
                    try self.emitLocal(s.closure);
                    try self.w().writeAll(".proc(");
                    try self.emitArgs(s.args);
                    if (self.store().getLocalSpan(s.args).len != 0) try self.w().writeAll(", ");
                    try self.emitLocal(s.closure);
                    try self.w().writeAll(".cap, ");
                    if (s.reuse_closure) {
                        try self.emitLocal(s.reuse_source orelse s.closure);
                    } else {
                        try self.w().writeAll("nil");
                    }
                    try self.w().writeAll(")\n");
                    current = s.next;
                },
                .assign_boxy_desc_ref,
                .assign_boxy_dict_ref,
                .assign_boxy_box,
                .assign_boxy_reuse_box,
                .assign_boxy_unbox,
                .assign_boxy_adapt,
                .assign_boxy_inspect,
                .assign_boxy_tag,
                .assign_boxy_tag_payload,
                .boxy_tag_match,
                .assign_call_dict,
                .store_struct,
                .store_tag,
                .expect_err,
                .comptime_exhaustiveness_failed,
                .loop_continue,
                .loop_break,
                => return self.refuse("statement {s}", .{@tagName(stmt)}),
                .str_match => |s| {
                    try self.emitStrMatchArm(s.source, s.prefix, s.steps, s.end, true, depth);
                    try self.emitChain(s.on_match, depth + 1, false);
                    return self.emitStrMatchMiss(s.on_miss, depth);
                },
                .str_match_set => |s| {
                    const arms = self.store().getStrMatchArms(s.arms);
                    if (arms.len == 0) return self.emitChain(s.on_miss, depth, false);
                    for (0..arms.len) |i| {
                        const arm = GuardedList.at(arms, i);
                        try self.emitStrMatchArm(s.source, arm.prefix, arm.steps, arm.end, i == 0, depth);
                        try self.emitChain(arm.on_match, depth + 1, false);
                    }
                    return self.emitStrMatchMiss(s.on_miss, depth);
                },
            }
        }
    }

    /// Emit a Lua condition that is true when the presence proof `cond` has
    /// the bits of `mask` set (a Bool proof uses mask 1).
    fn emitPresence(self: *Emitter, cond: LIR.LocalId, mask: u64) EmitError!void {
        switch (self.reprOfLocal(cond)) {
            .bool => {
                if (mask != 1) return self.refuse("bool presence proof with mask {d}", .{mask});
                try self.emitLocal(cond);
            },
            .u8, .u16, .u32 => {
                try self.w().writeAll("bit.band(");
                try self.emitLocal(cond);
                // Initialized when every mask bit is set (interpreter: `(v & mask) == mask`).
                try self.w().print(", {d}) == bit.tobit({d})", .{ mask, mask });
            },
            .u64 => {
                try self.w().writeAll("bit.band(");
                try self.emitLocal(cond);
                try self.w().print(", {d}ULL) == {d}ULL", .{ mask, mask });
            },
            .str, .zst, .i8, .i16, .i32, .i64, .i128, .u128, .dec, .f32, .f64, .other => return self.refuse("presence proof of {s}", .{@tagName(self.reprOfLocal(cond))}),
        }
    }

    fn emitArgs(self: *Emitter, span: LIR.LocalSpan) EmitError!void {
        const args = self.store().getLocalSpan(span);
        for (0..args.len) |i| {
            if (i != 0) try self.w().writeAll(", ");
            try self.emitLocal(GuardedList.at(args, i));
        }
    }

    /// Open one string-pattern arm (interpreter `execStrMatchArm`) as an
    /// `if`/`elseif` on `rt.str_match`, then bind the arm's view captures from
    /// `rt.cap` on its match edge. Arms are tried in order, as LIR requires.
    fn emitStrMatchArm(self: *Emitter, source: LIR.LocalId, prefix: LIR.StrLiteral, steps: LIR.StrMatchStepSpan, end: LIR.StrPatternEnd, first: bool, depth: usize) EmitError!void {
        try self.indent(depth);
        try self.w().writeAll(if (first) "if rt.str_match(" else "elseif rt.str_match(");
        try self.emitStrOperand(source);
        try self.w().writeAll(", ");
        try emitLuaString(self.w(), self.store().getStringLiteral(prefix));
        try self.w().writeAll(", {");
        const list = self.store().getStrMatchSteps(steps);
        for (0..list.len) |i| {
            if (i != 0) try self.w().writeAll(", ");
            try emitLuaString(self.w(), self.store().getStringLiteral(GuardedList.at(list, i).delimiter));
        }
        try self.w().print("}}, {s}) then\n", .{if (end == .tail) "true" else "false"});
        for (0..list.len) |i| {
            switch (GuardedList.at(list, i).capture) {
                .discard => {},
                .view => |local| {
                    try self.beginAssign(local, depth + 1);
                    try self.w().print("rt.cap[{d}]\n", .{i + 1});
                },
            }
        }
    }

    fn emitStrMatchMiss(self: *Emitter, on_miss: LIR.CFStmtId, depth: usize) EmitError!void {
        try self.indent(depth);
        try self.w().writeAll("else\n");
        try self.emitChain(on_miss, depth + 1, false);
        try self.indent(depth);
        try self.w().writeAll("end\n");
    }

    fn emitSwitch(self: *Emitter, s: anytype, depth: usize) EmitError!void {
        const cond_repr = self.reprOfLocal(s.cond);
        const branches = self.store().getCFSwitchBranches(s.branches);
        if (branches.len == 0) return self.emitChain(s.default_branch, depth, false);
        for (0..branches.len) |i| {
            const branch = GuardedList.at(branches, i);
            try self.indent(depth);
            try self.w().writeAll(if (i == 0) "if " else "elseif ");
            switch (cond_repr) {
                .bool => {
                    if (branch.value > 1) return self.refuse("bool switch on value {d}", .{branch.value});
                    if (branch.value == 0) try self.w().writeAll("not ");
                    try self.emitLocal(s.cond);
                },
                // readSwitchValue compares the unsigned bit pattern (or a tag
                // union's discriminant) with the branch value.
                .u8, .u16, .u32 => {
                    try self.emitLocal(s.cond);
                    try self.w().print(" == {d}", .{branch.value});
                },
                .i8, .i16, .i32 => {
                    const bits: u6 = if (cond_repr == .i8) 8 else if (cond_repr == .i16) 16 else 32;
                    try self.emitLocal(s.cond);
                    try self.w().print(" % {d} == {d}", .{ @as(u64, 1) << bits, branch.value });
                },
                .u64 => {
                    try self.emitLocal(s.cond);
                    try self.w().writeAll(" == ");
                    try self.emitIntLiteral(branch.value, .u64);
                },
                .i64 => {
                    try self.emitLocal(s.cond);
                    try self.w().writeAll(" == ");
                    try self.emitIntLiteral(@as(i64, @bitCast(branch.value)), .i64);
                },
                .zst => try self.w().writeAll(if (branch.value == 0) "true" else "false"),
                .other => {
                    if (self.layoutTag(self.layoutOfLocal(s.cond)) != .tag_union) return self.refuse("switch on {s}", .{@tagName(self.layoutTag(self.layoutOfLocal(s.cond)))});
                    if (self.localShape(s.cond)) |shape| {
                        try self.emitSlotName(self.leafSlots(s.cond).?[self.shape_nodes.items[shape].leaf_first]);
                        try self.w().print(" == {d}", .{branch.value});
                    } else {
                        try self.emitLocal(s.cond);
                        try self.w().print("[1] == {d}", .{branch.value});
                    }
                },
                .str, .i128, .u128, .dec, .f32, .f64 => return self.refuse("switch on {s}", .{@tagName(cond_repr)}),
            }
            try self.w().writeAll(" then\n");
            try self.emitChain(branch.body, depth + 1, false);
        }
        try self.indent(depth);
        try self.w().writeAll("else\n");
        try self.emitChain(s.default_branch, depth + 1, false);
        try self.indent(depth);
        try self.w().writeAll("end\n");
    }

    fn emitRc(self: *Emitter, comptime op: []const u8, value: LIR.LocalId, rc: LIR.RcHelper, count: u16, depth: usize) EmitError!void {
        const key = switch (rc) {
            .concrete => |helper| helper,
            .boxy => return self.refuse("boxy rc helper", .{}),
        };
        if (!try self.needsRcCall(key)) return;
        try self.indent(depth);
        try self.emitRcCallee(key);
        try self.w().writeAll("(");
        try self.emitLocal(value);
        if (comptime std.mem.eql(u8, op, "incref")) try self.w().print(", {d}", .{count});
        try self.w().writeAll(")\n");
    }

    /// Whether an RC helper does anything at runtime. Str is an immutable Lua
    /// string (see runtime.lua), so its plans, like `noop`, emit no call.
    fn needsRcCall(self: *Emitter, key: layout.RcHelper) EmitError!bool {
        return switch (self.layouts().rcHelperPlan(key)) {
            .noop, .str_incref, .str_decref, .str_free => false,
            .list_incref, .list_decref, .list_free, .box_incref, .box_decref, .box_free, .struct_, .tag_union => true,
            .erased_callable_incref, .erased_callable_decref, .erased_callable_free => true,
            .closure => self.refuse("closure rc", .{}),
        };
    }

    /// Name of the generated helper for `key` (`R.d42` = decref of layout 42),
    /// queued for definition after the procedures.
    fn emitRcCallee(self: *Emitter, key: layout.RcHelper) EmitError!void {
        try self.rc_helpers.put(self.gpa, key.encode(), {});
        const letter: u8 = switch (key.op.performed()) {
            .incref => 'i',
            .decref => 'd',
            .free => 'f',
        };
        try self.w().print("R.{c}{d}", .{ letter, @intFromEnum(key.layout_idx) });
    }

    fn emitRcChild(self: *Emitter, child: ?layout.RcHelper) EmitError!void {
        if (child) |key| if (try self.needsRcCall(key)) return self.emitRcCallee(key);
        try self.w().writeAll("nil");
    }

    /// Define every queued RC helper, following upstream's RC helper plans
    /// (layout/rc_helper.zig) over the Lua representations: lists and boxes
    /// carry a count in `rc`; structs index fields by semantic index + 1;
    /// tag unions hold [1] discriminant and [2] payload.
    fn emitRcHelpers(self: *Emitter) EmitError!void {
        // Table helpers and leaf helpers queue each other; define both until
        // neither queue grows.
        var i: usize = 0;
        var j: usize = 0;
        while (i < self.rc_helpers.count() or j < self.leaf_rc_helpers.count()) {
            if (i == self.rc_helpers.count()) {
                try self.emitLeafRcHelper(layout.RcHelper.decode(self.leaf_rc_helpers.keys()[j]));
                j += 1;
                continue;
            }
            defer i += 1;
            const key = layout.RcHelper.decode(self.rc_helpers.keys()[i]);
            const plan = self.layouts().rcHelperPlan(key);
            const incref = key.op.performed() == .incref;
            try self.emitRcCallee(key);
            try self.w().writeAll(if (incref) " = function(v, n)\n" else " = function(v)\n");
            switch (plan) {
                .noop, .str_incref, .str_decref, .str_free => {},
                .list_incref => |p| try self.w().print("\trt.L.incref(v, n, {s})\n", .{if (p.child != null) "true" else "false"}),
                .box_incref => try self.w().writeAll("\trt.box_incref(v, n)\n"),
                .list_decref, .list_free => |p| {
                    // A flat list's elements are released through the
                    // stride-k module and the leaf form of their helper.
                    try self.w().writeAll("\t");
                    try self.emitListModule(try self.listElemLayout(key.layout_idx));
                    try self.w().writeAll(if (plan == .list_decref) ".decref(v, " else ".free(v, ");
                    if (p.child) |child| {
                        try self.emitElemRc(child.op, child.layout_idx);
                    } else try self.w().writeAll("nil");
                    try self.w().writeAll(")\n");
                },
                .box_decref, .box_free => |p| {
                    try self.w().writeAll(if (plan == .box_decref) "\trt.box_decref(v, " else "\trt.box_free(v, ");
                    try self.emitRcChild(p.child);
                    try self.w().writeAll(")\n");
                },
                .struct_ => |sp| {
                    const count = self.layouts().rcHelperStructFieldCount(sp);
                    for (0..count) |sorted| {
                        const field_plan = self.layouts().rcHelperStructFieldPlan(sp, @intCast(sorted)) orelse continue;
                        if (!try self.needsRcCall(field_plan.child)) continue;
                        const semantic = self.layouts().getStructField(sp.struct_idx, @intCast(sorted)).index;
                        try self.w().writeAll("\t");
                        try self.emitRcCallee(field_plan.child);
                        try self.w().print("(v[{d}]{s})\n", .{ semantic + 1, if (field_plan.child.op.performed() == .incref) ", n" else "" });
                    }
                },
                .tag_union => |tp| {
                    const count = self.layouts().rcHelperTagUnionVariantCount(tp);
                    var first = true;
                    for (0..count) |variant| {
                        const child = self.layouts().rcHelperTagUnionVariantPlan(tp, @intCast(variant)) orelse continue;
                        if (!try self.needsRcCall(child)) continue;
                        try self.w().print("\t{s} v[1] == {d} then ", .{ if (first) "if" else "elseif", variant });
                        try self.emitRcCallee(child);
                        try self.w().print("(v[2]{s})\n", .{if (child.op.performed() == .incref) ", n" else ""});
                        first = false;
                    }
                    if (!first) try self.w().writeAll("\tend\n");
                },
                .erased_callable_incref => try self.w().writeAll("\trt.erased_incref(v, n)\n"),
                .erased_callable_decref => try self.w().writeAll("\trt.erased_decref(v)\n"),
                .erased_callable_free => try self.w().writeAll("\trt.erased_free(v)\n"),
                .closure => return self.refuse("closure rc", .{}),
            }
            try self.w().writeAll("end\n");
        }
    }

    /// Define a leaf-form element RC helper (`emitLeafRcCallee`): build the
    /// element's table from its leaves, then call the table helper.
    fn emitLeafRcHelper(self: *Emitter, key: layout.RcHelper) EmitError!void {
        const node = (try self.shapeOf(key.layout_idx)).?;
        const n = self.shape_nodes.items[node];
        const incref = key.op.performed() == .incref;
        try self.emitLeafRcCallee(key);
        try self.w().writeAll(" = function(");
        for (0..n.leaf_count) |k| try self.w().print("{s}l{d}", .{ if (k == 0) "" else ", ", k + 1 });
        try self.w().writeAll(if (incref) ", n)\n\t" else ")\n\t");
        try self.emitRcCallee(key);
        try self.w().writeAll("(");
        try self.emitElemHelper(key.layout_idx, false);
        try self.w().writeAll("(");
        for (0..n.leaf_count) |k| try self.w().print("{s}l{d}", .{ if (k == 0) "" else ", ", k + 1 });
        try self.w().writeAll(if (incref) "), n)\nend\n" else "))\nend\n");
    }

    /// Whether values of this layout hold a flat-stored list at any depth,
    /// so they need converting where hosts read or build them.
    fn needsHostConversion(self: *Emitter, idx: layout.Idx) EmitError!bool {
        if (self.host_conversion.get(idx)) |known| return known;
        // Recursive layouts reach themselves through lists and boxes; a
        // cycle adds nothing, so it counts as false until decided.
        try self.host_conversion.put(self.gpa, idx, false);
        const lay = self.layouts().getLayout(idx);
        const result = switch (lay.tag) {
            .scalar, .zst, .box_of_zst, .list_of_zst, .ptr, .closure, .erased_callable, .erased_box => false,
            .list => try self.elemStride(lay.getIdx()) > 1 or try self.needsHostConversion(lay.getIdx()),
            .box => try self.needsHostConversion(lay.getIdx()),
            .struct_ => blk: {
                const fields = self.layouts().getStructInfo(lay).fields;
                for (0..fields.len) |i| {
                    if (try self.needsHostConversion(fields.get(i).layout)) break :blk true;
                }
                break :blk false;
            },
            .tag_union => blk: {
                const variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(lay.getTagUnion().idx));
                for (0..variants.len) |i| {
                    if (try self.needsHostConversion(variants.get(i).payload_layout)) break :blk true;
                }
                break :blk false;
            },
        };
        try self.host_conversion.put(self.gpa, idx, result);
        return result;
    }

    /// Define the host converters the code calls: `R.h<layout>` turns a
    /// value's flat lists into lists of element tables (for a host to read),
    /// `R.g<layout>` the reverse (for a host-built value). Structs and tags
    /// are rebuilt with converted fields and payloads, boxes rewrapped.
    fn emitHostConverters(self: *Emitter) EmitError!void {
        var i: usize = 0;
        var j: usize = 0;
        while (i < self.host_to.count() or j < self.host_from.count()) {
            if (i < self.host_to.count()) {
                try self.emitHostConverter(self.host_to.keys()[i], true);
                i += 1;
            } else {
                try self.emitHostConverter(self.host_from.keys()[j], false);
                j += 1;
            }
        }
    }

    /// One converter body; `to_host` selects `R.h` over `R.g`.
    fn emitHostConverter(self: *Emitter, idx: layout.Idx, to_host: bool) EmitError!void {
        const letter: u8 = if (to_host) 'h' else 'g';
        try self.w().print("R.{c}{d} = function(v)\n", .{ letter, @intFromEnum(idx) });
        const lay = self.layouts().getLayout(idx);
        switch (lay.tag) {
            .list => {
                const elem = lay.getIdx();
                const k = try self.elemStride(elem);
                if (k > 1) {
                    try self.w().print("\treturn rt.{s}(v, {d}, ", .{ if (to_host) "list_to_tables" else "list_from_tables", k });
                    try self.emitElemHelper(elem, !to_host);
                    try self.w().writeAll(", ");
                } else {
                    try self.w().writeAll("\treturn rt.list_map_values(v, ");
                }
                if (try self.needsHostConversion(elem)) {
                    try self.emitHostConverterRef(elem, to_host);
                } else try self.w().writeAll("nil");
                try self.w().writeAll(")\n");
            },
            .box => {
                try self.w().writeAll("\treturn rt.box_new(");
                try self.emitHostConverterRef(lay.getIdx(), to_host);
                try self.w().writeAll("(v.v))\n");
            },
            .struct_ => {
                const sidx = lay.getStruct().idx;
                const count = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields()).len;
                try self.w().writeAll("\treturn {");
                for (0..count) |f| {
                    if (f != 0) try self.w().writeAll(", ");
                    const field = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, @intCast(f));
                    if (try self.needsHostConversion(field)) {
                        try self.emitHostConverterRef(field, to_host);
                        try self.w().print("(v[{d}])", .{f + 1});
                    } else try self.w().print("v[{d}]", .{f + 1});
                }
                try self.w().writeAll("}\n");
            },
            .tag_union => {
                const variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(lay.getTagUnion().idx));
                for (0..variants.len) |v| {
                    const payload = variants.get(v).payload_layout;
                    if (!try self.needsHostConversion(payload)) continue;
                    try self.w().print("\tif v[1] == {d} then return {{v[1], ", .{v});
                    try self.emitHostConverterRef(payload, to_host);
                    try self.w().writeAll("(v[2])} end\n");
                }
                try self.w().writeAll("\treturn v\n");
            },
            .scalar, .zst, .box_of_zst, .list_of_zst, .ptr, .closure, .erased_callable, .erased_box => return self.refuse("host conversion of {s}", .{@tagName(lay.tag)}),
        }
        try self.w().writeAll("end\n");
    }

    fn emitHostConverterRef(self: *Emitter, idx: layout.Idx, to_host: bool) EmitError!void {
        if (to_host) try self.host_to.put(self.gpa, idx, {}) else try self.host_from.put(self.gpa, idx, {});
        try self.w().print("R.{c}{d}", .{ @as(u8, if (to_host) 'h' else 'g'), @intFromEnum(idx) });
    }

    fn layouts(self: *Emitter) *const layout.Store {
        return self.input.layouts;
    }

    fn layoutOfLocal(self: *Emitter, local: LIR.LocalId) layout.Idx {
        return self.store().getLocal(local).layout_idx;
    }

    fn layoutTag(self: *Emitter, idx: layout.Idx) layout.LayoutTag {
        return self.layouts().getLayout(idx).tag;
    }

    fn isBoxLayout(self: *Emitter, idx: layout.Idx) bool {
        return switch (self.layoutTag(idx)) {
            .box, .box_of_zst, .erased_box => true,
            .scalar, .list, .list_of_zst, .struct_, .closure, .erased_callable, .zst, .tag_union, .ptr => false,
        };
    }

    /// Write `local` read as a value of layout `expected`, following the
    /// interpreter's explicit-ref coercion (boxy_runtime): layouts other than
    /// box and unboxed share one representation; crossing the box boundary
    /// wraps a fresh box or reads the boxed value out.
    fn emitCoerced(self: *Emitter, local: LIR.LocalId, expected: layout.Idx) EmitError!void {
        const actual = self.layoutOfLocal(local);
        try self.emitValueCoerced(local, actual, expected);
    }

    fn emitValueCoerced(self: *Emitter, local: LIR.LocalId, actual: layout.Idx, expected: layout.Idx) EmitError!void {
        if (actual == expected) return self.emitLocal(local);
        const actual_box = self.isBoxLayout(actual);
        const expected_box = self.isBoxLayout(expected);
        if (actual_box == expected_box) {
            // Same side of boxing: the interpreter reinterprets bytes. Lua
            // values share a representation unless the scalar class differs.
            if (reprOf(actual) != reprOf(expected)) {
                return self.refuse("reinterpret layout {d} as {d}", .{ @intFromEnum(actual), @intFromEnum(expected) });
            }
            return self.emitLocal(local);
        }
        if (expected_box) {
            if (self.layoutTag(expected) != .box) return self.refuse("coerce into {s}", .{@tagName(self.layoutTag(expected))});
            try self.w().writeAll("rt.box_new(");
            try self.emitLocal(local);
            return self.w().writeAll(")");
        }
        if (self.layoutTag(actual) != .box) return self.refuse("coerce out of {s}", .{@tagName(self.layoutTag(actual))});
        try self.emitLocal(local);
        try self.w().writeAll(".v");
    }

    /// Write the struct or tag-union value inside `local`, reading through a
    /// box when the local's layout is a box of it (resolveStructBaseValue).
    fn emitAggregateBase(self: *Emitter, local: LIR.LocalId) EmitError!layout.Idx {
        const idx = self.layoutOfLocal(local);
        try self.emitLocal(local);
        if (self.layoutTag(idx) == .box) {
            try self.w().writeAll(".v");
            return self.layouts().getLayout(idx).getIdx();
        }
        return idx;
    }

    fn emitStructLiteral(self: *Emitter, fields: LIR.LocalSpan, struct_layout: layout.Idx) EmitError!void {
        const sl = self.layouts().getLayout(struct_layout);
        const locals = self.store().getLocalSpan(fields);
        try self.w().writeAll("{");
        for (0..locals.len) |i| {
            if (i != 0) try self.w().writeAll(", ");
            const field_layout = self.layouts().getStructFieldLayoutByOriginalIndex(sl.getStruct().idx, @intCast(i));
            try self.emitCoerced(GuardedList.at(locals, i), field_layout);
        }
        try self.w().writeAll("}");
    }

    /// The value of `idx` whose bytes are all zero: what the interpreter's
    /// zero-filled result memory holds where a builtin writes nothing (for
    /// example a parse Result's Err payload). Tag unions take discriminant 0.
    fn emitZeroValue(self: *Emitter, idx: layout.Idx) EmitError!void {
        if (idx == .bool) return self.w().writeAll("false");
        if (idx == .str) return self.w().writeAll("\"\"");
        if (isVectorLayout(idx)) return self.w().writeAll("rt.V.zero()");
        switch (self.layoutTag(idx)) {
            .zst => try self.w().writeAll("rt.ZST"),
            .scalar => switch (reprOf(idx)) {
                .u8, .i8, .u16, .i16, .u32, .i32, .u64, .i64, .f32, .f64 => try self.w().writeAll("0"),
                .i128, .u128, .dec => try self.emitWideConst(0),
                .bool, .str, .zst, .other => return self.refuse("zero value of scalar {s}", .{@tagName(reprOf(idx))}),
            },
            .list, .list_of_zst => try self.w().writeAll("rt.L.empty()"),
            .struct_ => {
                const sidx = self.layouts().getLayout(idx).getStruct().idx;
                const count = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields()).len;
                try self.w().writeAll("{");
                for (0..count) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    try self.emitZeroValue(self.layouts().getStructFieldLayoutByOriginalIndex(sidx, @intCast(i)));
                }
                try self.w().writeAll("}");
            },
            .tag_union => {
                try self.w().writeAll("{0, ");
                try self.emitZeroValue(self.tagVariantPayloadLayout(idx, 0));
                try self.w().writeAll("}");
            },
            .box, .box_of_zst, .erased_box, .closure, .erased_callable, .ptr => return self.refuse("zero value of {s}", .{@tagName(self.layoutTag(idx))}),
        }
    }

    fn emitAssignStruct(self: *Emitter, target: LIR.LocalId, fields: LIR.LocalSpan, depth: usize) EmitError!void {
        const target_layout = self.layoutOfLocal(target);
        if (self.localShape(target)) |shape| {
            const slots = self.leafSlots(target).?;
            const sidx = self.layouts().getLayout(target_layout).getStruct().idx;
            const locals = self.store().getLocalSpan(fields);
            for (0..locals.len) |i| {
                const field_layout = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, @intCast(i));
                try self.emitFillFromLocal(self.shapeChild(shape, i), slots, field_layout, GuardedList.at(locals, i), depth);
            }
            return;
        }
        try self.beginAssign(target, depth);
        switch (self.layoutTag(target_layout)) {
            .zst => try self.w().writeAll("rt.ZST"),
            .struct_ => try self.emitStructLiteral(fields, target_layout),
            .box => {
                const inner = self.layouts().getLayout(target_layout).getIdx();
                if (self.layoutTag(inner) != .struct_) return self.refuse("assign_struct into box of {s}", .{@tagName(self.layoutTag(inner))});
                try self.w().writeAll("rt.box_new(");
                try self.emitStructLiteral(fields, inner);
                try self.w().writeAll(")");
            },
            .scalar, .box_of_zst, .erased_box, .list, .list_of_zst, .closure, .erased_callable, .tag_union, .ptr => return self.refuse("assign_struct into {s}", .{@tagName(self.layoutTag(target_layout))}),
        }
        try self.w().writeAll("\n");
    }

    fn tagVariantPayloadLayout(self: *Emitter, union_layout: layout.Idx, variant_index: u16) layout.Idx {
        const tu = self.layouts().getLayout(union_layout).getTagUnion();
        const variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(tu.idx));
        return variants.get(variant_index).payload_layout;
    }

    fn emitTagLiteral(self: *Emitter, union_layout: layout.Idx, variant_index: u16, discriminant: u16, payload: ?LIR.LocalId) EmitError!void {
        try self.w().print("{{{d}", .{discriminant});
        if (payload) |local| {
            const payload_layout = self.tagVariantPayloadLayout(union_layout, variant_index);
            try self.w().writeAll(", ");
            try self.emitCoerced(local, payload_layout);
        }
        try self.w().writeAll("}");
    }

    fn emitAssignTag(self: *Emitter, s: anytype, depth: usize) EmitError!void {
        if (s.target_desc != null) return self.refuse("descriptor-carrying tag", .{});
        const target_layout = self.layoutOfLocal(s.target);
        if (target_layout == .bool) {
            if (s.payload) |payload| if (self.layoutWidth(self.layoutOfLocal(payload)) != 0) return self.refuse("bool tag with payload", .{});
            try self.beginAssign(s.target, depth);
            try self.w().writeAll(if (s.discriminant == 1) "true\n" else "false\n");
            return;
        }
        if (self.localShape(s.target)) |shape| {
            const slots = self.leafSlots(s.target).?;
            try self.indent(depth);
            try self.emitSlotName(slots[self.shape_nodes.items[shape].leaf_first]);
            try self.w().print(" = {d}\n", .{s.discriminant});
            if (s.payload) |payload| {
                const payload_layout = self.tagVariantPayloadLayout(target_layout, s.variant_index);
                try self.emitFillFromLocal(self.shapeChild(shape, s.variant_index), slots, payload_layout, payload, depth);
            }
            return;
        }
        try self.beginAssign(s.target, depth);
        switch (self.layoutTag(target_layout)) {
            .zst => try self.w().writeAll("rt.ZST"),
            .tag_union => try self.emitTagLiteral(target_layout, s.variant_index, s.discriminant, s.payload),
            .box => {
                const inner = self.layouts().getLayout(target_layout).getIdx();
                if (self.layoutTag(inner) != .tag_union) return self.refuse("assign_tag into box of {s}", .{@tagName(self.layoutTag(inner))});
                try self.w().writeAll("rt.box_new(");
                try self.emitTagLiteral(inner, s.variant_index, s.discriminant, s.payload);
                try self.w().writeAll(")");
            },
            .scalar, .box_of_zst, .erased_box, .list, .list_of_zst, .struct_, .closure, .erased_callable, .ptr => return self.refuse("assign_tag into {s}", .{@tagName(self.layoutTag(target_layout))}),
        }
        try self.w().writeAll("\n");
    }

    /// Lower `assign_ref`: projections read the representation the
    /// constructors above build (struct: semantic index + 1; tag union:
    /// [1] discriminant, [2] payload).
    fn emitAssignRef(self: *Emitter, target: LIR.LocalId, op: LIR.RefOp, depth: usize) EmitError!void {
        const target_layout = self.layoutOfLocal(target);
        if (try self.emitFlatRef(target, op, depth)) return;
        switch (op) {
            .local => |source| {
                try self.beginAssign(target, depth);
                try self.emitCoerced(source, target_layout);
            },
            .list_reinterpret => |r| {
                try self.beginAssign(target, depth);
                try self.emitLocal(r.backing_ref);
            },
            .nominal => |r| {
                try self.beginAssign(target, depth);
                try self.emitCoerced(r.backing_ref, target_layout);
            },
            .field => |f| {
                const base_layout = self.layoutOfLocal(f.source);
                const struct_layout = if (self.layoutTag(base_layout) == .box) self.layouts().getLayout(base_layout).getIdx() else base_layout;
                if (self.layoutTag(struct_layout) != .struct_) return self.refuse("field of {s}", .{@tagName(self.layoutTag(struct_layout))});
                const field_layout = self.layouts().getStructFieldLayoutByOriginalIndex(self.layouts().getLayout(struct_layout).getStruct().idx, f.field_idx);
                if (self.layoutTag(field_layout) != .zst and target_layout != field_layout and self.isBoxLayout(field_layout) != self.isBoxLayout(target_layout)) {
                    return self.refuse("field coercion across boxing", .{});
                }
                try self.beginAssign(target, depth);
                if (self.layouts().getStructFieldSizeByOriginalIndex(self.layouts().getLayout(struct_layout).getStruct().idx, f.field_idx) == 0) {
                    try self.w().writeAll("rt.ZST");
                } else {
                    _ = try self.emitAggregateBase(f.source);
                    try self.w().print("[{d}]", .{f.field_idx + 1});
                }
            },
            .discriminant => |d| {
                const base_layout = self.layoutOfLocal(d.source);
                try self.beginAssign(target, depth);
                if (base_layout == .bool) {
                    try self.w().writeAll("(");
                    try self.emitLocal(d.source);
                    try self.w().writeAll(" and 1 or 0)");
                } else if (self.layoutTag(base_layout) == .zst) {
                    try self.w().writeAll("0");
                } else {
                    _ = try self.emitAggregateBase(d.source);
                    try self.w().writeAll("[1]");
                }
            },
            .tag_payload => |p| {
                const base_layout = self.layoutOfLocal(p.source);
                const union_layout = if (self.layoutTag(base_layout) == .box) self.layouts().getLayout(base_layout).getIdx() else base_layout;
                if (self.layoutTag(union_layout) != .tag_union) return self.refuse("tag payload of {s}", .{@tagName(self.layoutTag(union_layout))});
                const payload_layout = self.tagVariantPayloadLayout(union_layout, p.variant_index);
                try self.beginAssign(target, depth);
                switch (self.layoutTag(payload_layout)) {
                    .struct_ => {
                        const sidx = self.layouts().getLayout(payload_layout).getStruct().idx;
                        if (self.layouts().getStructFieldSizeByOriginalIndex(sidx, p.payload_idx) == 0) {
                            try self.w().writeAll("rt.ZST");
                        } else {
                            _ = try self.emitAggregateBase(p.source);
                            try self.w().print("[2][{d}]", .{p.payload_idx + 1});
                        }
                    },
                    .zst => try self.w().writeAll("rt.ZST"),
                    .scalar, .box, .box_of_zst, .erased_box, .list, .list_of_zst, .closure, .erased_callable, .tag_union, .ptr => {
                        if (payload_layout != target_layout and self.isBoxLayout(payload_layout) != self.isBoxLayout(target_layout)) {
                            return self.refuse("tag payload coercion across boxing", .{});
                        }
                        _ = try self.emitAggregateBase(p.source);
                        try self.w().writeAll("[2]");
                    },
                }
            },
            .tag_payload_struct => |p| {
                const base_layout = self.layoutOfLocal(p.source);
                const union_layout = if (self.layoutTag(base_layout) == .box) self.layouts().getLayout(base_layout).getIdx() else base_layout;
                if (self.layoutTag(union_layout) != .tag_union) return self.refuse("tag payload struct of {s}", .{@tagName(self.layoutTag(union_layout))});
                const payload_layout = self.tagVariantPayloadLayout(union_layout, p.variant_index);
                try self.beginAssign(target, depth);
                if (self.layoutTag(payload_layout) == .zst) {
                    try self.w().writeAll("rt.ZST");
                } else {
                    if (payload_layout != target_layout and self.isBoxLayout(payload_layout) != self.isBoxLayout(target_layout)) {
                        return self.refuse("tag payload struct coercion across boxing", .{});
                    }
                    _ = try self.emitAggregateBase(p.source);
                    try self.w().writeAll("[2]");
                }
            },
        }
        try self.w().writeAll("\n");
    }

    fn listElemLayout(self: *Emitter, list_layout: layout.Idx) EmitError!layout.Idx {
        return switch (self.layoutTag(list_layout)) {
            .list => self.layouts().getLayout(list_layout).getIdx(),
            .list_of_zst => .zst,
            .scalar, .box, .box_of_zst, .erased_box, .struct_, .closure, .erased_callable, .zst, .tag_union, .ptr => self.refuse("list op on {s}", .{@tagName(self.layoutTag(list_layout))}),
        };
    }

    fn layoutWidth(self: *Emitter, idx: layout.Idx) u32 {
        return self.layouts().layoutSizeAlign(self.layouts().getLayout(idx)).size;
    }

    /// Element RC helper for list builtins (`listElementIncref`/`Decref`), or
    /// `nil` when the element needs no RC call. A flat list's elements are
    /// passed as their leaves, so it gets the leaf form (`emitLeafRcCallee`).
    fn emitElemRc(self: *Emitter, op: layout.RcOp, elem: layout.Idx) EmitError!void {
        const key: layout.RcHelper = .{ .op = op, .layout_idx = elem };
        if (!try self.needsRcCall(key)) return self.w().writeAll("nil");
        if (try self.elemStride(elem) > 1) return self.emitLeafRcCallee(key);
        return self.emitRcCallee(key);
    }

    /// Leaves per element in list storage (list.lua's stride k): an element
    /// whose layout flattens to two or more leaves is stored as its leaves
    /// (flat list storage, which lets LuaJIT read and write elements without
    /// a table per element); every other element takes one slot, as a Lua
    /// value or the layout's table.
    fn elemStride(self: *Emitter, elem: layout.Idx) EmitError!u32 {
        const node = try self.shapeOf(elem) orelse return 1;
        const n = self.shape_nodes.items[node].leaf_count;
        return if (n >= 2) n else 1;
    }

    /// The list.lua module for elements of `elem`: `rt.L`, or the stride-k
    /// module `rt.LF[k]` for flat storage.
    fn emitListModule(self: *Emitter, elem: layout.Idx) EmitError!void {
        const k = try self.elemStride(elem);
        if (k == 1) return self.w().writeAll("rt.L");
        try self.w().print("rt.LF[{d}]", .{k});
    }

    /// A flat list element's leaves from a local of the element's shape.
    fn emitElemLeaves(self: *Emitter, local: LIR.LocalId, elem: layout.Idx) EmitError!void {
        const slots = self.leafSlots(local) orelse return self.refuse("flat list element in a table-valued local", .{});
        const node = (try self.shapeOf(elem)).?;
        const local_shape = self.localShape(local).?;
        if (local_shape != node and !self.sameShape(local_shape, node)) return self.refuse("flat list element of another shape (local layout {d} {s}, {d} leaves; element layout {d} {s}, {d} leaves)", .{ @intFromEnum(self.layoutOfLocal(local)), @tagName(self.layoutTag(self.layoutOfLocal(local))), self.shape_nodes.items[local_shape].leaf_count, @intFromEnum(elem), @tagName(self.layoutTag(elem)), self.shape_nodes.items[node].leaf_count });
        try self.emitLeafList(slots);
    }

    /// Name of the materializer (`R.m`) or unpacker (`R.u`) of a flat
    /// element layout, queued for definition.
    fn emitElemHelper(self: *Emitter, elem: layout.Idx, unpacker: bool) EmitError!void {
        const node = (try self.shapeOf(elem)).?;
        if (unpacker) {
            try self.unpackers.put(self.gpa, elem, node);
            return self.w().print("R.u{d}", .{@intFromEnum(elem)});
        }
        try self.materializers.put(self.gpa, elem, node);
        try self.w().print("R.m{d}", .{@intFromEnum(elem)});
    }

    /// Leaf form of an element RC helper for flat list storage (`R.iL42` /
    /// `R.dL42` over the k leaves): it builds the element's table and calls
    /// the table helper, so it allocates; elements needing RC calls are
    /// those holding lists, boxes or closures.
    fn emitLeafRcCallee(self: *Emitter, key: layout.RcHelper) EmitError!void {
        try self.leaf_rc_helpers.put(self.gpa, key.encode(), {});
        const letter: u8 = switch (key.op.performed()) {
            .incref => 'i',
            .decref => 'd',
            .free => 'f',
        };
        try self.w().print("R.{c}L{d}", .{ letter, @intFromEnum(key.layout_idx) });
    }

    fn emitAssignList(self: *Emitter, target: LIR.LocalId, elems: LIR.LocalSpan, depth: usize) EmitError!void {
        const elem = try self.listElemLayout(self.layoutOfLocal(target));
        const locals = self.store().getLocalSpan(elems);
        try self.beginAssign(target, depth);
        // The allocation's refcount fields are in the constructor, so the
        // table is created with its hash part instead of rehashed when
        // `literal` stores them. Flat elements contribute their leaves.
        const flat = try self.elemStride(elem) > 1;
        try self.w().print("rt.L.literal({d}, {{[0] = 1", .{self.layoutWidth(elem)});
        for (0..locals.len) |i| {
            try self.w().writeAll(", ");
            if (flat) {
                try self.emitElemLeaves(GuardedList.at(locals, i), elem);
            } else {
                try self.emitCoerced(GuardedList.at(locals, i), elem);
            }
        }
        try self.w().print("}}, {d})\n", .{locals.len});
    }

    /// Lower a List low-level op to its list.lua entry point. `shape` lists
    /// the call's arguments: digits are operand positions, `W` the element
    /// width, `I`/`D` the element incref/decref helpers, `P`/`Q` the update
    /// modes of operands 0/1 (true = InPlace), `R` whether elements are
    /// refcounted, `X` the op's interchangeable flag, `S` the list field of a
    /// split result pair.
    fn emitListOp(self: *Emitter, s: anytype, name: []const u8, shape: []const u8) EmitError!void {
        const args = self.store().getLocalSpan(s.args);
        const elem = try self.listOpElemLayout(s);
        const flat = try self.elemStride(elem) > 1;
        try self.emitListModule(elem);
        try self.w().print(".ll_{s}(", .{name});
        for (shape, 0..) |c, i| {
            // The materializer and unpacker are passed only for flat storage.
            if ((c == 'M' or c == 'U') and !flat) continue;
            if (i != 0) try self.w().writeAll(", ");
            switch (c) {
                'b', 'c' => {
                    // An element operand (position 1 or 2): its leaves for
                    // flat storage, else the value.
                    const pos = c - 'a';
                    if (pos >= args.len) return self.refuse("{s} arity {d}", .{ @tagName(s.op), args.len });
                    if (flat) {
                        if (self.layoutOfLocal(GuardedList.at(args, pos)) != elem) {
                            return self.refuse("{s}: element layout {d}, value layout {d}", .{ @tagName(s.op), @intFromEnum(elem), @intFromEnum(self.layoutOfLocal(GuardedList.at(args, pos))) });
                        }
                        try self.emitElemLeaves(GuardedList.at(args, pos), elem);
                    } else {
                        try self.emitLocal(GuardedList.at(args, pos));
                    }
                },
                'M' => try self.emitElemHelper(elem, false),
                'U' => try self.emitElemHelper(elem, true),
                '0'...'3' => {
                    const pos = c - '0';
                    if (pos >= args.len) return self.refuse("{s} arity {d}", .{ @tagName(s.op), args.len });
                    try self.emitLocal(GuardedList.at(args, pos));
                },
                'W' => try self.w().print("{d}", .{self.layoutWidth(elem)}),
                'I' => try self.emitElemRc(.incref, elem),
                'D' => try self.emitElemRc(.decref, elem),
                'P' => try self.w().writeAll(if (s.unique_args & 1 != 0 or s.op == .list_set_in_place_unsafe) "true" else "false"),
                'Q' => try self.w().writeAll(if (s.unique_args & 2 != 0) "true" else "false"),
                'R' => try self.w().writeAll(if (self.layouts().layoutContainsRefcounted(self.layouts().getLayout(elem))) "true" else "false"),
                'X' => try self.w().writeAll(if (try self.mapCanReuseInPlace(s, elem)) "true" else "false"),
                'S' => try self.w().print("{d}", .{try self.splitListPosition(s.target)}),
                else => unreachable, // shapes are the literals in emitListLowLevel
            }
        }
        try self.w().writeAll(")");
    }

    /// Whether `List.map` may write its results into the input's allocation:
    /// LIR's `interchangeable` (same size, alignment and refcounting), and
    /// no more leaves per output element than per input element, since the
    /// in-place loop writes element i's slots after reading only elements
    /// 0..i (with k_out <= k_in the writes stay within those).
    fn mapCanReuseInPlace(self: *Emitter, s: anytype, in_elem: layout.Idx) EmitError!bool {
        if (!s.interchangeable.get(self.layouts().targetUsize())) return false;
        const out_elem = s.map_output_elem orelse return self.refuse("list_map_can_reuse without its output element layout", .{});
        return try self.elemStride(out_elem) <= try self.elemStride(in_elem);
    }

    /// Semantic position (1 or 2) of the list in a split result's Ok pair
    /// (resolveListElementPairStruct).
    fn splitListPosition(self: *Emitter, target: LIR.LocalId) EmitError!u8 {
        const union_layout = self.layoutOfLocal(target);
        if (self.layoutTag(union_layout) != .tag_union) return self.refuse("split result layout {s}", .{@tagName(self.layoutTag(union_layout))});
        const pair_layout = self.tagVariantPayloadLayout(union_layout, 1);
        if (self.layoutTag(pair_layout) != .struct_) return self.refuse("split pair layout {s}", .{@tagName(self.layoutTag(pair_layout))});
        const sidx = self.layouts().getLayout(pair_layout).getStruct().idx;
        const f0 = self.layoutTag(self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 0));
        return if (f0 == .list or f0 == .list_of_zst) 1 else 2;
    }

    /// Lower a SIMD `assign_low_level` to `rt.V` (simd.lua). The operand kind
    /// is the first vector argument's layout, else the result's, exactly as
    /// the interpreter's `evalSimd` chooses it. Returns false for other ops.
    fn emitSimdLowLevel(self: *Emitter, s: anytype, depth: usize) EmitError!bool {
        const index = s.op.simdOpIndex() orelse return false;
        const shape = simd_shapes[index];
        const args = self.store().getLocalSpan(s.args);
        const ret = self.layoutOfLocal(s.target);
        var arg_kind: ?layout.Idx = null;
        for (0..args.len) |i| {
            const arg_layout = self.layoutOfLocal(GuardedList.at(args, i));
            if (isVectorLayout(arg_layout)) {
                arg_kind = arg_layout;
                break;
            }
        }
        const ret_kind: ?layout.Idx = if (isVectorLayout(ret)) ret else null;
        const source = arg_kind orelse ret_kind orelse return self.refuse("{s} without a vector operand", .{@tagName(s.op)});
        const destination = ret_kind orelse source;
        try self.beginAssign(s.target, depth);
        // Sums of lanes up to 32 bits come back as exact numbers, which are
        // valid I64/U64 values as they are.
        try self.w().print("rt.V.{s}(", .{shape[0]});
        for (shape[1], 0..) |c, i| {
            if (i != 0) try self.w().writeAll(", ");
            switch (c) {
                'A' => try self.w().print("rt.V.{s}", .{@tagName(source)}),
                'R' => try self.w().print("rt.V.{s}", .{@tagName(destination)}),
                '0'...'2' => {
                    const pos = c - '0';
                    if (pos >= args.len) return self.refuse("{s} arity {d}", .{ @tagName(s.op), args.len });
                    try self.emitLocal(GuardedList.at(args, pos));
                },
                'Q' => try self.w().writeAll(if (s.unique_args & 2 != 0) "true" else "false"),
                else => unreachable, // shapes are the literals in simd_shapes
            }
        }
        try self.w().writeAll(")\n");
        return true;
    }

    /// Lower an `assign_low_level` whose op works on lists. Returns false when
    /// `op` is not a list op, so the caller uses the scalar lowering.
    /// The element layout a list op stores or reads, which selects its
    /// stride. In-place `List.map` reads input elements from, and writes
    /// output elements into, one allocation through a list local of a single
    /// type, so its extract and write take the element's own layout (the
    /// extract's target, the written value).
    fn listOpElemLayout(self: *Emitter, s: anytype) EmitError!layout.Idx {
        const args = self.store().getLocalSpan(s.args);
        if (s.op == .list_map_extract_unsafe) return self.layoutOfLocal(s.target);
        if (s.op == .list_map_write_unsafe) return self.layoutOfLocal(GuardedList.at(args, 2));
        if (s.op == .list_with_capacity) return try self.listElemLayout(self.layoutOfLocal(s.target));
        return try self.listElemLayout(self.layoutOfLocal(GuardedList.at(args, 0)));
    }

    fn emitListLowLevel(self: *Emitter, s: anytype, depth: usize) EmitError!bool {
        const shape = list_shapes.get(s.op) orelse return false;
        if ((s.op == .list_get_unsafe or s.op == .list_map_extract_unsafe) and try self.elemStride(try self.listOpElemLayout(s)) > 1) {
            // A flat element comes back as its leaves, straight into the
            // target's leaves.
            const elem = try self.listOpElemLayout(s);
            try self.indent(depth);
            try self.emitElemLeaves(s.target, elem);
            try self.w().writeAll(" = ");
            try self.emitListOp(s, shape[0], shape[1]);
            try self.w().writeAll("\n");
            return true;
        }
        try self.beginAssign(s.target, depth);
        if (shape[0].len == 0) {
            // Reinterpretations of the same list value.
            try self.emitLocal(GuardedList.at(self.store().getLocalSpan(s.args), 0));
        } else if (s.op == .list_replace_unsafe) {
            // Result record { list, value }: field order from its layout.
            const ret = self.layoutOfLocal(s.target);
            if (self.layoutTag(ret) != .struct_) return self.refuse("list_replace_unsafe result {s}", .{@tagName(self.layoutTag(ret))});
            const f0 = self.layoutTag(self.layouts().getStructFieldLayoutByOriginalIndex(self.layouts().getLayout(ret).getStruct().idx, 0));
            const elem = try self.listElemLayout(self.layoutOfLocal(GuardedList.at(self.store().getLocalSpan(s.args), 0)));
            if (try self.elemStride(elem) > 1) {
                // The old element comes back as its leaves.
                try self.w().writeAll(if (f0 == .list or f0 == .list_of_zst) "rt.record_lv_flat(" else "rt.record_vl_flat(");
                try self.emitElemHelper(elem, false);
                try self.w().writeAll(", ");
            } else {
                try self.w().writeAll(if (f0 == .list or f0 == .list_of_zst) "rt.record_lv(" else "rt.record_vl(");
            }
            try self.emitListOp(s, shape[0], shape[1]);
            try self.w().writeAll(")");
        } else if (s.op == .list_map_can_reuse and reprOf(self.layoutOfLocal(s.target)) != .bool) {
            try self.w().writeAll("(");
            try self.emitListOp(s, shape[0], shape[1]);
            try self.w().writeAll(" and 1 or 0)");
        } else {
            try self.emitListOp(s, shape[0], shape[1]);
        }
        try self.w().writeAll("\n");
        return true;
    }

    fn emitLiteral(self: *Emitter, value: LIR.LiteralValue, target: LIR.LocalId) EmitError!void {
        const bump: i128 = switch (self.options.mutation) {
            .none => 0,
            .int_literals => 1,
            .dec_literals => 0,
        };
        const dec_bump: i128 = switch (self.options.mutation) {
            .none, .int_literals => 0,
            .dec_literals => 1,
        };
        switch (value) {
            .i64_literal => |lit| try self.emitIntLiteral(@as(i128, lit.value) + bump, lit.layout_idx),
            .i128_literal => |lit| try self.emitIntLiteral(lit.value +% bump, lit.layout_idx),
            .dec_literal => |bits| try self.emitWideConst(bits +% dec_bump),
            .str_literal => |lit| try emitLuaString(self.w(), self.store().getStringLiteral(lit)),
            .f64_literal => |v| try emitFloatLiteral(self.w(), v),
            .f32_literal => |v| try emitFloatLiteral(self.w(), v),
            .bytes_literal => |lit| try self.emitBytesLiteral(lit, target),
            .static_data => |id| {
                try self.static_slots.put(self.gpa, @intFromEnum(id), self.layoutOfLocal(target));
                try self.w().print("SD[{d}]", .{@intFromEnum(id)});
            },
            .boxy_dynamic_num_literal,
            .boxy_dynamic_frac_literal,
            .null_ptr,
            .proc_ref,
            => return self.refuse("literal {s}", .{@tagName(value)}),
        }
    }

    /// A 128-bit constant in a procedure body: a read of the shared `WK` slot
    /// for its bit pattern, so a loop does not build the limb table on every
    /// iteration. Sharing is sound because the runtime never mutates a wide
    /// value it is given (wide.lua and int128.lua return fresh tables).
    fn emitWideConst(self: *Emitter, value: i128) EmitError!void {
        const entry = try self.wide_consts.getOrPut(self.gpa, @bitCast(value));
        try self.w().print("WK[{d}]", .{entry.index + 1});
    }

    /// Build each 128-bit constant the procedures read, once at load.
    fn emitWideConsts(self: *Emitter) EmitError!void {
        for (self.wide_consts.keys(), 1..) |bits, slot| {
            try self.w().print("WK[{d}] = ", .{slot});
            try emitWideLiteral(self.w(), @bitCast(bits));
            try self.w().writeAll("\n");
        }
    }

    /// Build each static data slot the procedures read, once at load
    /// (`SD[id]`), from its frozen export. Static values are never unique
    /// (native refcount 0), so one shared Lua value serves every read.
    /// Static data is built by `init_static_data()`, called once the
    /// helpers it uses (flat lists' unpackers) are defined.
    fn emitStaticData(self: *Emitter) EmitError!void {
        if (self.static_slots.count() != 0 and self.layouts().targetUsize() != .u64) return self.refuse("static data for a 32-bit target", .{});
        try self.w().writeAll("local function init_static_data()\n");
        for (self.static_slots.keys(), self.static_slots.values()) |id, slot_layout| {
            const index = for (self.input.static_data, 0..) |item, i| {
                if (item.value_id) |value_id| if (@intFromEnum(value_id) == id) break i;
            } else return self.refuse("static data slot {d} without frozen bytes", .{id});
            try self.w().print("SD[{d}] = ", .{id});
            try self.emitFrozenValue(index, self.input.static_data[index].symbol_offset, slot_layout);
            try self.w().writeAll("\n");
        }
        try self.w().writeAll("end\n");
    }

    /// The export and offset a pointer word at `offset` in export `index`
    /// relocates to (the addend skips any allocation header).
    fn frozenPointee(self: *Emitter, index: usize, offset: usize) EmitError!struct { index: usize, offset: usize } {
        const item = self.input.static_data[index];
        const relocation = for (item.relocations) |r| {
            if (r.offset == offset) break r;
        } else return self.refuse("static data pointer without a relocation", .{});
        if (relocation.kind != .address) return self.refuse("static data function pointer", .{});
        const target: usize = switch (relocation.target) {
            .data_symbol => |symbol| @intFromEnum(symbol),
            .named => for (self.input.static_data, 0..) |other, i| {
                if (std.mem.eql(u8, other.symbol_name, relocation.target_symbol_name)) break i;
            } else return self.refuse("static data relocation to {s}", .{relocation.target_symbol_name}),
        };
        return .{ .index = target, .offset = @intCast(@as(i64, @intCast(self.input.static_data[target].symbol_offset)) + relocation.addend) };
    }

    fn frozenWord(self: *Emitter, index: usize, offset: usize) u64 {
        return std.mem.readInt(u64, self.input.static_data[index].bytes[offset..][0..8], .little);
    }

    /// One frozen value as a Lua constructor, decoded by its layout from the
    /// target-ABI bytes `static_data.buildStaticData` produced: RocStr and
    /// RocList descriptors follow their relocations, records and tag unions
    /// read fields and discriminants at the layout's offsets.
    fn emitFrozenValue(self: *Emitter, index: usize, offset: usize, idx: layout.Idx) EmitError!void {
        const bytes = self.input.static_data[index].bytes;
        // Bool layout (also any union of exactly two unit variants) is a Lua
        // boolean everywhere else; a `{ discriminant, ZST }` table would be
        // truthy for both variants.
        if (idx == .bool) return self.w().writeAll(if (bytes[offset] != 0) "true" else "false");
        if (idx == .str) {
            const length = self.frozenWord(index, offset + 16);
            if (@as(i64, @bitCast(length)) < 0) {
                return emitLuaString(self.w(), bytes[offset..][0 .. bytes[offset + 23] & 0x7f]);
            }
            if (length == 0) return self.w().writeAll("\"\"");
            const pointee = try self.frozenPointee(index, offset);
            return emitLuaString(self.w(), self.input.static_data[pointee.index].bytes[pointee.offset..][0..@intCast(length)]);
        }
        switch (self.layoutTag(idx)) {
            .scalar => return self.emitBytesValue(idx, bytes[offset..][0..self.layoutWidth(idx)]),
            .zst => return self.w().writeAll("rt.ZST"),
            .struct_ => {
                const sidx = self.layouts().getLayout(idx).getStruct().idx;
                const count = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields()).len;
                try self.w().writeAll("{");
                for (0..count) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    const field = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, @intCast(i));
                    const field_offset = self.layouts().getStructFieldOffsetByOriginalIndex(sidx, @intCast(i));
                    try self.emitFrozenValue(index, offset + field_offset, field);
                }
                try self.w().writeAll("}");
            },
            .tag_union => {
                const data = self.layouts().getTagUnionData(self.layouts().getLayout(idx).getTagUnion().idx);
                const discriminant = data.readDiscriminant(bytes.ptr + offset, .u64);
                const payload = self.layouts().getTagUnionVariants(data).get(discriminant).payload_layout;
                try self.w().print("{{{d}, ", .{discriminant});
                try self.emitFrozenValue(index, offset, payload);
                try self.w().writeAll("}");
            },
            .list, .list_of_zst => {
                const length = self.frozenWord(index, offset + 8);
                if (length == 0) {
                    for (self.input.static_data[index].empty_list_capacities) |item| {
                        if (item.offset == offset and item.capacity != 0) return self.refuse("static empty list with capacity {d}", .{item.capacity});
                    }
                    return self.w().writeAll("rt.L.empty()");
                }
                if (self.layoutTag(idx) == .list_of_zst) return self.w().print("rt.L.zst({d})", .{length});
                const elem = self.layouts().getLayout(idx).getIdx();
                const width = self.layoutWidth(elem);
                const pointee = try self.frozenPointee(index, offset);
                try self.emitStaticListOpen(elem, length, false);
                for (0..@intCast(length)) |i| {
                    try self.w().writeAll(", ");
                    try self.emitFrozenValue(pointee.index, pointee.offset + i * width, elem);
                }
                try self.w().print("}}, {d})", .{width});
            },
            .box => {
                const pointee = try self.frozenPointee(index, offset);
                try self.w().writeAll("{ rc = 0, v = ");
                try self.emitFrozenValue(pointee.index, pointee.offset, self.layouts().getLayout(idx).getIdx());
                try self.w().writeAll(" }");
            },
            // Box.box({}) allocates nothing natively; rt.box_new gives it a
            // box like any other, so its static form is a static box of ZST.
            .box_of_zst => return self.w().writeAll("{ rc = 0, v = rt.ZST }"),
            .erased_box, .closure, .erased_callable, .ptr => return self.refuse("static data of {s}", .{@tagName(self.layoutTag(idx))}),
        }
    }

    /// The head of a static list constructor up to its element values:
    /// `rt.L.static(n, slice, {[0] = 0`, or for flat storage
    /// `rt.flat_static(k, R.u<elem>, n, slice, {` (elements written as
    /// tables, unpacked into leaves once, at load).
    fn emitStaticListOpen(self: *Emitter, elem: layout.Idx, n: u64, slice: bool) EmitError!void {
        const k = try self.elemStride(elem);
        if (k == 1) return self.w().print("rt.L.static({d}, {s}, {{[0] = 0", .{ n, if (slice) "true" else "false" });
        try self.w().print("rt.flat_static({d}, ", .{k});
        try self.emitElemHelper(elem, true);
        // `[0] = 0` keeps the element list's first comma like the other form.
        try self.w().print(", {d}, {s}, {{[0] = 0", .{ n, if (slice) "true" else "false" });
    }

    /// A static byte-list literal (evalBytesLiteral): raw little-endian element
    /// storage decoded into Lua values, in a static list (refcount 0) that
    /// covers its whole backing or is a seamless slice of it.
    fn emitBytesLiteral(self: *Emitter, lit: LIR.ListLiteral, target: LIR.LocalId) EmitError!void {
        const elem = try self.listElemLayout(self.layoutOfLocal(target));
        const width = self.layoutWidth(elem);
        const bytes = self.store().getStringLiteral(lit.bytes);
        const backing = self.store().getStringLiteralBacking(lit.bytes);
        const whole = lit.bytes.offset == 0 and lit.bytes.len == backing.len;
        if (width != 0 and bytes.len != @as(usize, lit.len) * width) return self.refuse("bytes literal of {d} bytes for {d} elements", .{ bytes.len, lit.len });
        try self.emitStaticListOpen(elem, lit.len, !whole);
        for (0..lit.len) |i| {
            try self.w().writeAll(", ");
            if (width == 0) {
                try self.w().writeAll("rt.ZST");
                continue;
            }
            try self.emitBytesValue(elem, bytes[i * width ..][0..width]);
        }
        try self.w().print("}}, {d})", .{width});
    }

    /// One value decoded from its native little-endian bytes (evalBytesLiteral
    /// copies element storage verbatim): scalars, vectors, and structs field by
    /// field at their layout offsets, in original field order.
    fn emitBytesValue(self: *Emitter, layout_idx: layout.Idx, chunk: []const u8) EmitError!void {
        const repr = reprOf(layout_idx);
        switch (repr) {
            .u8 => try self.w().print("{d}", .{chunk[0]}),
            .i8 => try self.w().print("{d}", .{@as(i8, @bitCast(chunk[0]))}),
            .u16 => try self.w().print("{d}", .{std.mem.readInt(u16, chunk[0..2], .little)}),
            .i16 => try self.w().print("{d}", .{std.mem.readInt(i16, chunk[0..2], .little)}),
            .u32 => try self.w().print("{d}", .{std.mem.readInt(u32, chunk[0..4], .little)}),
            .i32 => try self.w().print("{d}", .{std.mem.readInt(i32, chunk[0..4], .little)}),
            .u64, .i64 => try self.emitIntLiteral(if (repr == .u64) std.mem.readInt(u64, chunk[0..8], .little) else std.mem.readInt(i64, chunk[0..8], .little), layout_idx),
            .i128, .u128, .dec => try emitWideLiteral(self.w(), std.mem.readInt(i128, chunk[0..16], .little)),
            .f32 => try emitFloatLiteral(self.w(), @as(f32, @bitCast(std.mem.readInt(u32, chunk[0..4], .little)))),
            .f64 => try emitFloatLiteral(self.w(), @as(f64, @bitCast(std.mem.readInt(u64, chunk[0..8], .little)))),
            .bool => try self.w().writeAll(if (chunk[0] != 0) "true" else "false"),
            .zst => try self.w().writeAll("rt.ZST"),
            .str => return self.refuse("bytes literal of str elements", .{}),
            .other => {
                if (isVectorLayout(layout_idx)) {
                    try self.w().writeAll("rt.V.from_u128_bits(");
                    try emitWideLiteral(self.w(), std.mem.readInt(i128, chunk[0..16], .little));
                    return self.w().writeAll(")");
                }
                if (self.layoutTag(layout_idx) == .zst) return self.w().writeAll("rt.ZST");
                if (self.layoutTag(layout_idx) != .struct_) return self.refuse("bytes literal of {s} elements", .{@tagName(self.layoutTag(layout_idx))});
                const sidx = self.layouts().getLayout(layout_idx).getStruct().idx;
                const count = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields()).len;
                try self.w().writeAll("{");
                for (0..count) |i| {
                    if (i != 0) try self.w().writeAll(", ");
                    const field = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, @intCast(i));
                    const offset = self.layouts().getStructFieldOffsetByOriginalIndex(sidx, @intCast(i));
                    try self.emitBytesValue(field, chunk[offset..][0..self.layoutWidth(field)]);
                }
                try self.w().writeAll("}");
            },
        }
    }

    fn emitIntLiteral(self: *Emitter, value: i128, layout_idx: layout.Idx) EmitError!void {
        const out = self.w();
        if (layout_idx == .bool and (value == 0 or value == 1)) {
            // The interpreter stores the literal's byte into the Bool.
            return out.writeAll(if (value == 1) "true" else "false");
        }
        if (isVectorLayout(layout_idx)) {
            // A vector constant is its 128-bit pattern (`from_u128_bits`).
            try out.writeAll("rt.V.from_u128_bits(");
            try emitWideLiteral(out, value);
            return out.writeAll(")");
        }
        const repr = reprOf(layout_idx);
        if (!fitsRepr(value, repr)) {
            return self.refuse("integer literal {d} outside layout {d}", .{ value, @intFromEnum(layout_idx) });
        }
        switch (repr) {
            .u8, .i8, .u16, .i16, .u32, .i32 => try out.print("{d}", .{value}),
            // I64/U64 values below 2^53 in magnitude are Lua numbers; the rest
            // are int64/uint64 cdata (runtime.lua, "64-bit integers").
            .i64 => {
                const v: i64 = @intCast(value);
                if (v == std.math.minInt(i64)) {
                    try out.writeAll("(-9223372036854775807LL - 1LL)");
                } else if (@abs(v) < lua_exact_int_limit) {
                    if (v < 0) try out.print("({d})", .{v}) else try out.print("{d}", .{v});
                } else if (v < 0) {
                    try out.print("({d}LL)", .{v});
                } else {
                    try out.print("{d}LL", .{v});
                }
            },
            .u64 => {
                const v: u64 = if (value < 0) @bitCast(@as(i64, @intCast(value))) else @intCast(value);
                if (v < lua_exact_int_limit) try out.print("{d}", .{v}) else try out.print("{d}ULL", .{v});
            },
            .i128, .u128 => try self.emitWideConst(value),
            .bool, .str, .zst, .dec, .f32, .f64, .other => unreachable, // fitsRepr rejects them
        }
    }

    /// The single field of a one-field struct whose field has original index
    /// 0 (boxy_runtime.unwrapSingleFieldPayloadLayout), or null.
    fn unwrapSingleField(self: *Emitter, idx: layout.Idx) ?layout.Idx {
        if (self.layoutTag(idx) != .struct_) return null;
        const sidx = self.layouts().getLayout(idx).getStruct().idx;
        const fields = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields());
        if (fields.len != 1) return null;
        const field = fields.get(0);
        if (field.index != 0) return null;
        return field.layout;
    }

    /// Whether `idx` is Str.from_utf8's BadUtf8 record: two fields, original
    /// index 0 a U64 byte index, 1 the one-byte problem (findBadUtf8Variant).
    fn isBadUtf8Record(self: *Emitter, idx: layout.Idx) bool {
        if (self.layoutTag(idx) != .struct_) return false;
        const sidx = self.layouts().getLayout(idx).getStruct().idx;
        const fields = self.layouts().struct_fields.sliceRange(self.layouts().getStructData(sidx).getFields());
        if (fields.len != 2) return false;
        return self.layoutWidth(self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 0)) == 8 and
            self.layoutWidth(self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 1)) == 1;
    }

    /// `{ index, problem }` in the record's representation; `index` is a U64
    /// cdata and `problem` the Utf8ByteProblem code from the runtime.
    fn emitBadUtf8Record(self: *Emitter, idx: layout.Idx) EmitError!void {
        const sidx = self.layouts().getLayout(idx).getStruct().idx;
        if (self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 0) != .u64) return self.refuse("BadUtf8 index layout", .{});
        const problem = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 1);
        if (problem == .u8) {
            try self.w().writeAll("{index, problem}");
        } else if (self.layoutTag(problem) == .tag_union) {
            try self.w().writeAll("{index, {problem}}");
        } else {
            return self.refuse("BadUtf8 problem layout {s}", .{@tagName(self.layoutTag(problem))});
        }
    }

    /// Str.from_utf8 into its Result layout, resolved as the interpreter's
    /// str_from_utf8 does: Ok is the variant whose (unwrapped) payload is Str;
    /// Err holds the BadUtf8 record directly or as a variant of an open error
    /// union. Single-field wrappers become one-element Lua arrays.
    fn emitStrFromUtf8(self: *Emitter, span: LIR.LocalSpan, target: LIR.LocalId) EmitError!void {
        const ret = self.layoutOfLocal(target);
        if (self.layoutTag(ret) != .tag_union) return self.refuse("str_from_utf8 into {s}", .{@tagName(self.layoutTag(ret))});
        const tu = self.layouts().getLayout(ret).getTagUnion();
        const variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(tu.idx));
        var ok: ?u16 = null;
        var err: ?u16 = null;
        for (0..variants.len) |i| {
            const payload = variants.get(i).payload_layout;
            const candidate = self.unwrapSingleField(payload) orelse payload;
            if (candidate == .str) ok = @intCast(i) else err = @intCast(i);
        }
        const ok_disc = ok orelse return self.refuse("str_from_utf8 without an Ok variant", .{});
        const err_disc = err orelse return self.refuse("str_from_utf8 without an Err variant", .{});
        const ok_payload = variants.get(ok_disc).payload_layout;
        const err_payload = variants.get(err_disc).payload_layout;
        try self.w().writeAll("rt.str_from_utf8(");
        try self.emitArgs(span);
        try self.w().print(", function(s) return {{{d}, ", .{ok_disc});
        try self.w().writeAll(if (self.unwrapSingleField(ok_payload) != null) "{s}" else "s");
        try self.w().print("}} end, function(index, problem) return {{{d}, ", .{err_disc});
        const err_wrapped = self.unwrapSingleField(err_payload);
        const candidate = err_wrapped orelse err_payload;
        if (err_wrapped != null) try self.w().writeAll("{");
        switch (self.layoutTag(candidate)) {
            .struct_ => {
                if (!self.isBadUtf8Record(candidate)) return self.refuse("str_from_utf8 Err record layout", .{});
                try self.emitBadUtf8Record(candidate);
            },
            .tag_union => {
                const inner = self.layouts().getLayout(candidate).getTagUnion();
                const inner_variants = self.layouts().getTagUnionVariants(self.layouts().getTagUnionData(inner.idx));
                var found: ?u16 = null;
                for (0..inner_variants.len) |i| {
                    const p = inner_variants.get(i).payload_layout;
                    if (self.isBadUtf8Record(self.unwrapSingleField(p) orelse p)) {
                        found = @intCast(i);
                        break;
                    }
                }
                const k = found orelse return self.refuse("str_from_utf8 Err union without BadUtf8", .{});
                const p = inner_variants.get(k).payload_layout;
                const record = self.unwrapSingleField(p);
                try self.w().print("{{{d}, ", .{k});
                if (record != null) try self.w().writeAll("{");
                try self.emitBadUtf8Record(record orelse p);
                if (record != null) try self.w().writeAll("}");
                try self.w().writeAll("}");
            },
            .scalar, .box, .box_of_zst, .erased_box, .list, .list_of_zst, .closure, .erased_callable, .zst, .ptr => return self.refuse("str_from_utf8 Err payload {s}", .{@tagName(self.layoutTag(candidate))}),
        }
        if (err_wrapped != null) try self.w().writeAll("}");
        try self.w().writeAll("} end)");
    }

    /// Whether a Hasher value of layout `idx` is a bare U64 (false) or a
    /// one-field struct around it (true); refuses anything else. The
    /// interpreter reads and writes the U64 at offset 0 (writeHasherValue).
    fn hasherWrapped(self: *Emitter, idx: layout.Idx) EmitError!bool {
        if (idx == .u64) return false;
        if (self.unwrapSingleField(idx)) |inner| if (inner == .u64) return true;
        return self.refuse("hasher layout {s}", .{@tagName(self.layoutTag(idx))});
    }

    /// A hasher op whose result is a Hasher (a one-field record around the
    /// U64 state) held in a flattened local: the new state goes straight into
    /// that local's single leaf instead of through a `{ state }` table and its
    /// unpacker, which removes an allocation from every Dict/Set hash write.
    fn emitHasherIntoLeaf(self: *Emitter, s: anytype, depth: usize) EmitError!bool {
        if (lowerings.get(s.op) != .hasher) return false;
        const slots = self.leafSlots(s.target) orelse return false;
        if (!try self.hasherWrapped(self.layoutOfLocal(s.target))) return false;
        try self.indent(depth);
        try self.emitSlotName(slots[0]);
        try self.w().writeAll(" = ");
        self.hasher_into_leaf = true;
        defer self.hasher_into_leaf = false;
        try self.emitHasher(s.op, s.args, s.target);
        try self.w().writeAll("\n");
        return true;
    }

    /// Dict/Set hashing (builtins/hash.zig via rt.hash_*): the op's
    /// hasherDomain and width come from upstream's lir helpers.
    fn emitHasher(self: *Emitter, op: LowLevel, span: LIR.LocalSpan, target: LIR.LocalId) EmitError!void {
        const args = self.store().getLocalSpan(span);
        const wrap_out = (try self.hasherWrapped(self.layoutOfLocal(target))) and !self.hasher_into_leaf;
        if (wrap_out) try self.w().writeAll("{");
        if (op == .dict_pseudo_seed) {
            try self.w().writeAll("rt.dict_pseudo_seed()");
        } else {
            const h = GuardedList.at(args, 0);
            const wrap_in = try self.hasherWrapped(self.layoutOfLocal(h));
            const stem: []const u8 = if (op == .hasher_finish)
                "finish"
            else if (op == .hasher_write_f32)
                "write_f32"
            else if (op == .hasher_write_f64)
                "write_f64"
            else if (op == .hasher_write_str)
                "write_str"
            else if (op == .hasher_write_bytes)
                "write_bytes"
            else if (op == .hasher_write_u128 or op == .hasher_write_i128 or op == .hasher_write_dec)
                "write_wide"
            else
                "write_int";
            try self.w().print("rt.hash_{s}(", .{stem});
            if (wrap_in and self.leafSlots(h) != null) {
                // The wrapped state's single leaf.
                try self.emitSlotName(self.leafSlots(h).?[0]);
            } else {
                try self.emitLocal(h);
                if (wrap_in) try self.w().writeAll("[1]");
            }
            if (op != .hasher_finish) {
                if (std.mem.eql(u8, stem, "write_int") or std.mem.eql(u8, stem, "write_wide")) {
                    try self.w().print(", {d}", .{@intFromEnum(lir.hasherDomain(op))});
                }
                try self.w().writeAll(", ");
                try self.emitLocal(GuardedList.at(args, 1));
                if (std.mem.eql(u8, stem, "write_int")) try self.w().print(", {d}", .{lir.hasherU64Width(op)});
            }
            try self.w().writeAll(")");
        }
        if (wrap_out) try self.w().writeAll("}");
    }

    /// Lower a number parse (base/numeric_conversion.zig parse specs) to the
    /// runtime's numparse port. `*_from_str` builds the Result the interpreter
    /// writes (Ok 1 with the number; Err 0 with the zero-filled payload);
    /// prefix parses build the `{ err : U8, rest, value }` record of
    /// writePrefixParse, in semantic field order.
    fn emitNumParse(self: *Emitter, op: LowLevel, span: LIR.LocalSpan, target: LIR.LocalId) EmitError!void {
        const arg = GuardedList.at(self.store().getLocalSpan(span), 0);
        const ret = self.layoutOfLocal(target);
        const prefix = numeric_conversion.getNumericPrefixParseSpec(op);
        const spec = if (prefix) |p| p.parse else numeric_conversion.getNumericParseSpec(op).?;
        const kind: []const u8, const num: []const u8 = switch (spec) {
            .int => |int| .{ "int", switch (int.width_bytes) {
                1 => if (int.signed) "i8" else "u8",
                2 => if (int.signed) "i16" else "u16",
                4 => if (int.signed) "i32" else "u32",
                8 => if (int.signed) "i64" else "u64",
                16 => if (int.signed) "i128" else "u128",
                else => return self.refuse("{s} width {d}", .{ @tagName(op), int.width_bytes }),
            } },
            .float => |float| .{ "float", if (float.width_bytes == 4) "f32" else "f64" },
            .dec => .{ "dec", "dec" },
        };
        if (prefix) |p| {
            if (self.layoutTag(ret) != .struct_) return self.refuse("{s} into {s}", .{ @tagName(op), @tagName(self.layoutTag(ret)) });
            const sidx = self.layouts().getLayout(ret).getStruct().idx;
            const err_layout = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 0);
            const value_layout = self.layouts().getStructFieldLayoutByOriginalIndex(sidx, 2);
            if (err_layout != .u8 or !std.mem.eql(u8, reprOf(value_layout).numName() orelse "", num)) {
                return self.refuse("{s} record layout", .{@tagName(op)});
            }
            try self.w().writeAll("rt.num_from_prefix(");
            try self.emitLocal(arg);
            try self.w().print(", \"{s}\", \"{s}\", {s})", .{ kind, num, if (p.source == .utf8) "true" else "false" });
            return;
        }
        if (self.layoutTag(ret) != .tag_union) return self.refuse("{s} into {s}", .{ @tagName(op), @tagName(self.layoutTag(ret)) });
        if (!std.mem.eql(u8, reprOf(self.tagVariantPayloadLayout(ret, 1)).numName() orelse "", num)) {
            return self.refuse("{s} result layout", .{@tagName(op)});
        }
        try self.w().writeAll("rt.num_from_str(");
        try self.emitLocal(arg);
        try self.w().print(", \"{s}\", \"{s}\", ", .{ kind, num });
        try self.emitZeroValue(self.tagVariantPayloadLayout(ret, 0));
        try self.w().writeAll(")");
    }

    /// Whether every value of integer kind `src` is also a value of `dst`, so
    /// the conversion is a plain move: the runtime represents both the same
    /// way (a number, or for 64-bit kinds a number below 2^53 in magnitude
    /// and cdata above it).
    fn losslessIntConversion(src: numeric_conversion.NumType, dst: numeric_conversion.NumType) bool {
        if (src == dst) return true;
        if (!src.isSigned()) return dst.bits() > src.bits();
        return dst.isSigned() and dst.bits() >= src.bits();
    }

    /// Lower a number conversion from upstream's declarative spec
    /// (base/numeric_conversion.zig) to the runtime's cvt_* functions.
    fn emitConversion(self: *Emitter, op: LowLevel, span: LIR.LocalSpan) EmitError!void {
        const spec = numeric_conversion.getConversionSpec(op).?;
        const src = @tagName(spec.src);
        const dst = @tagName(spec.dst);
        const out = self.w();
        const arg = GuardedList.at(self.store().getLocalSpan(span), 0);
        const unsupported = self.refuse("{s}", .{@tagName(op)});
        switch (spec.src.class()) {
            .int => switch (spec.dst.class()) {
                .int => switch (spec.mode) {
                    .exact, .wrap => {
                        if (spec.src.bits() <= 64 and spec.dst.bits() <= 64) {
                            if (losslessIntConversion(spec.src, spec.dst)) return self.emitLocal(arg);
                            try out.print("rt.cvt_{s}_{s}(", .{ src, dst });
                            try self.emitLocal(arg);
                            return out.writeAll(")");
                        }
                        try out.writeAll("rt.cvt_int(");
                    },
                    .@"try" => try out.writeAll("rt.cvt_int_try("),
                    .trunc, .try_unsafe => return unsupported,
                },
                .dec => switch (spec.mode) {
                    .exact => try out.writeAll("rt.cvt_int_dec("),
                    .try_unsafe => try out.writeAll("rt.cvt_int_dec_try("),
                    .wrap, .trunc, .@"try" => return unsupported,
                },
                .float => switch (spec.mode) {
                    .exact => {
                        try out.writeAll("rt.cvt_int_float(");
                        try self.emitLocal(arg);
                        return out.print(", \"{s}\", {s})", .{ src, if (spec.dst == .f32) "true" else "false" });
                    },
                    .wrap, .trunc, .@"try", .try_unsafe => return unsupported,
                },
            },
            .float => {
                const is_f32 = if (spec.src == .f32) "true" else "false";
                switch (spec.dst.class()) {
                    .int => {
                        switch (spec.mode) {
                            .trunc => try out.writeAll("rt.cvt_float_int("),
                            .try_unsafe => try out.writeAll("rt.cvt_float_int_try("),
                            .exact, .wrap, .@"try" => return unsupported,
                        }
                        try self.emitLocal(arg);
                        return out.print(", {s}, \"{s}\")", .{ is_f32, dst });
                    },
                    .float => {
                        switch (spec.mode) {
                            .exact => try out.writeAll("("),
                            .wrap => try out.writeAll("rt.cvt_f64_f32("),
                            .try_unsafe => try out.writeAll("rt.cvt_f64_f32_try("),
                            .trunc, .@"try" => return unsupported,
                        }
                        try self.emitLocal(arg);
                        return out.writeAll(")");
                    },
                    .dec => return unsupported,
                }
            },
            .dec => switch (spec.dst.class()) {
                .int => switch (spec.mode) {
                    .trunc => try out.writeAll("rt.cvt_dec_int("),
                    .try_unsafe => try out.writeAll("rt.cvt_dec_int_try("),
                    .exact, .wrap, .@"try" => return unsupported,
                },
                .float => {
                    switch (spec.mode) {
                        .exact, .wrap => {
                            try out.writeAll("rt.cvt_dec_float(");
                            try self.emitLocal(arg);
                            return out.print(", {s})", .{if (spec.dst == .f32) "true" else "false"});
                        },
                        .try_unsafe => {
                            if (spec.dst != .f32) return unsupported;
                            try out.writeAll("rt.cvt_dec_f32_try(");
                            try self.emitLocal(arg);
                            return out.writeAll(")");
                        },
                        .trunc, .@"try" => return unsupported,
                    }
                },
                .dec => return unsupported,
            },
        }
        try self.emitLocal(arg);
        if (spec.src == .dec) return out.print(", \"{s}\")", .{dst});
        if (spec.dst == .dec) return out.print(", \"{s}\")", .{src});
        try out.print(", \"{s}\", \"{s}\")", .{ src, dst });
    }

    fn emitBoxOp(self: *Emitter, op: LowLevel, arg: LIR.LocalId, target: LIR.LocalId) EmitError!void {
        const target_layout = self.layoutOfLocal(target);
        if (op == .box_box) {
            switch (self.layoutTag(target_layout)) {
                .box, .box_of_zst => {},
                .scalar, .erased_box, .list, .list_of_zst, .struct_, .closure, .erased_callable, .zst, .tag_union, .ptr => return self.refuse("box_box into {s}", .{@tagName(self.layoutTag(target_layout))}),
            }
            try self.w().writeAll("rt.box_new(");
            try self.emitLocal(arg);
            return self.w().writeAll(")");
        }
        if (op == .box_unbox or op == .box_unbox_borrowed) {
            if (self.layoutTag(target_layout) == .zst) return self.w().writeAll("rt.ZST");
            try self.emitLocal(arg);
            return self.w().writeAll(".v");
        }
        // box_prepare_update
        const box_layout = self.layoutOfLocal(arg);
        if (self.layoutTag(box_layout) != .box) return self.refuse("box_prepare_update on {s}", .{@tagName(self.layoutTag(box_layout))});
        const payload = self.layouts().getLayout(box_layout).getIdx();
        try self.w().writeAll("rt.box_prepare_update(");
        try self.emitLocal(arg);
        try self.w().writeAll(", false, ");
        try self.w().writeAll(if (self.layoutWidth(payload) == 0) "true, " else "false, ");
        try self.emitElemRc(.incref, payload);
        try self.w().writeAll(", ");
        try self.emitRcChild(.{ .op = .decref, .layout_idx = box_layout });
        try self.w().writeAll(")");
    }

    /// Checked integer add and sub with the exact fast path inline: the
    /// runtime's checked op (which crashes with the message on overflow) runs
    /// only when the result leaves it. Lua numbers hold every value of the 8-
    /// to 32-bit types, and I64/U64 values below 2^53 in magnitude (mixed
    /// representation, runtime.lua), so a Lua-number result strictly inside
    /// the type's range is exact. Anything else (an int64/uint64 cdata
    /// operand, a sum rounded to 2^53, an overflow) is recomputed by the
    /// runtime. Inlining avoids a call per operation in hot integer code.
    fn emitInlineCheckedArith(self: *Emitter, s: anytype, depth: usize) EmitError!bool {
        const symbol: []const u8 = if (s.op == .num_int_add_crash_on_overflow)
            "+"
        else if (s.op == .num_int_sub_crash_on_overflow)
            "-"
        else
            return false;
        if (self.leafSlots(s.target) != null) return false;
        const args = self.store().getLocalSpan(s.args);
        if (args.len != 2) return false;
        const repr = self.reprOfLocal(GuardedList.at(args, 0));
        const slow_when: []const u8 = switch (repr) {
            .i64 => "type(ck) ~= \"number\" or ck <= -9007199254740992 or ck >= 9007199254740992",
            .u64 => "type(ck) ~= \"number\" or ck < 0 or ck >= 9007199254740992",
            .i32 => "ck < -2147483648 or ck > 2147483647",
            .u32 => "ck < 0 or ck > 4294967295",
            .i16 => "ck < -32768 or ck > 32767",
            .u16 => "ck < 0 or ck > 65535",
            .i8 => "ck < -128 or ck > 127",
            .u8 => "ck < 0 or ck > 255",
            .i128, .u128, .dec, .f32, .f64, .bool, .str, .zst, .other => return false,
        };
        const message = CheckedArithmetic.overflowMessage(s.op) orelse return false;
        const a = GuardedList.at(args, 0);
        const b = GuardedList.at(args, 1);
        const out = self.w();
        try self.indent(depth);
        try out.writeAll("do local ck = ");
        try self.emitLocal(a);
        try out.print(" {s} ", .{symbol});
        try self.emitLocal(b);
        try out.print(" if {s} then ck = rt.{s}_checked_{s}(", .{ slow_when, arithName(s.op), repr.numName().? });
        try self.emitLocal(a);
        try out.writeAll(", ");
        try self.emitLocal(b);
        try out.writeAll(", ");
        try emitLuaString(out, message);
        try out.writeAll(") end ");
        try self.emitLocal(s.target);
        try out.writeAll(" = ck end\n");
        return true;
    }

    fn emitLowLevel(self: *Emitter, op: LowLevel, span: LIR.LocalSpan, target: LIR.LocalId) EmitError!void {
        const saved = self.str_operands;
        self.str_operands = !viewAwareStrOp(op);
        defer self.str_operands = saved;
        const args = self.store().getLocalSpan(span);
        if (args.len == 0) {
            if (lowerings.get(op) == .hasher) return self.emitHasher(op, span, target);
            if (lowerings.get(op) == .runtime_call) return self.w().print("rt.{s}()", .{@tagName(op)});
            return self.refuse("low_level {s}", .{@tagName(op)});
        }
        const operand = self.reprOfLocal(GuardedList.at(args, 0));
        switch (lowerings.get(op)) {
            .unsupported => return self.refuse("low_level {s}", .{@tagName(op)}),
            .wrapping_arith => {
                const n = operand.numName() orelse return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (operand == .f32 or operand == .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                // The interpreter gives integer-family mul on Dec decimal semantics.
                if (operand == .dec and std.mem.eql(u8, arithName(op), "mul")) return self.refuse("{s} on dec", .{@tagName(op)});
                try self.w().print("rt.{s}_wrap_{s}(", .{ arithName(op), n });
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .checked_arith => {
                const n = operand.numName() orelse return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (operand == .f32 or operand == .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (operand == .dec and std.mem.eql(u8, arithName(op), "mul")) return self.refuse("{s} on dec", .{@tagName(op)});
                const message = CheckedArithmetic.overflowMessage(op) orelse
                    return self.refuse("no overflow message for {s}", .{@tagName(op)});
                try self.w().print("rt.{s}_checked_{s}(", .{ arithName(op), n });
                try self.emitArgs(span);
                try self.w().writeAll(", ");
                try emitLuaString(self.w(), message);
                try self.w().writeAll(")");
            },
            .compare => {
                if (operand.numName() == null) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (args.len != 2) return self.refuse("{s} arity {d}", .{ @tagName(op), args.len });
                if (operand.isWide()) {
                    try self.w().print("(rt.cmp_{s}(", .{operand.numName().?});
                    try self.emitArgs(span);
                    try self.w().print("){s}0)", .{compareOperator(op)});
                    return;
                }
                try self.w().writeAll("(");
                try self.emitLocal(GuardedList.at(args, 0));
                try self.w().writeAll(compareOperator(op));
                try self.emitLocal(GuardedList.at(args, 1));
                try self.w().writeAll(")");
            },
            .bool_not => {
                try self.w().writeAll("not ");
                try self.emitArgs(span);
            },
            .int_to_str => {
                try self.w().print("rt.{s}(", .{@tagName(op)});
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .dec_mul => {
                if (operand != .dec or args.len != 2) return self.refuse("dec_mul on {s}", .{@tagName(operand)});
                try self.w().writeAll("rt.dec_mul(");
                try self.emitArgs(span);
                try self.w().writeAll(", \"Decimal multiplication overflowed!\")");
            },
            .division => {
                if (args.len != 2) return self.refuse("{s} arity {d}", .{ @tagName(op), args.len });
                const layout_idx = self.store().getLocal(GuardedList.at(args, 0)).layout_idx;
                if (operand == .dec) {
                    // decBinOp: Dec has no checked division forms in LIR.
                    const helper: []const u8 = if (op == .num_div_by)
                        "dec_div"
                    else if (op == .num_div_trunc_by)
                        "dec_div_trunc"
                    else if (op == .num_rem_by)
                        "dec_rem"
                    else if (op == .num_mod_by)
                        "dec_mod"
                    else
                        return self.refuse("{s} on dec", .{@tagName(op)});
                    try self.w().print("rt.{s}(", .{helper});
                    try self.emitArgs(span);
                    try self.w().writeAll(")");
                    return;
                }
                if (operand == .f32 or operand == .f64) {
                    // floatBinOp: / is IEEE division; // truncates; rem and mod are fmod.
                    if (op == .num_div_by) {
                        try self.w().writeAll(if (operand == .f32) "rt.f32(" else "(");
                        try self.emitLocal(GuardedList.at(args, 0));
                        try self.w().writeAll(" / ");
                        try self.emitLocal(GuardedList.at(args, 1));
                        return self.w().writeAll(")");
                    }
                    if (op != .num_div_trunc_by and op != .num_rem_by and op != .num_mod_by) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                    try self.w().print("rt.{s}_{s}(", .{ divisionStem(op), @tagName(operand) });
                    try self.emitArgs(span);
                    return self.w().writeAll(")");
                }
                if (!operand.isInt()) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                const stem = divisionStem(op);
                const zero_message = CheckedArithmetic.zeroDenominatorMessage(op, layout_idx);
                try self.w().print("rt.{s}{s}_{s}(", .{ stem, if (zero_message != null) "_checked" else "", operand.numName().? });
                try self.emitArgs(span);
                if (zero_message) |message| {
                    try self.w().writeAll(", ");
                    try emitLuaString(self.w(), message);
                    if (std.mem.eql(u8, stem, "div_trunc")) {
                        try self.w().writeAll(", ");
                        try emitLuaString(self.w(), CheckedArithmetic.overflowMessage(op) orelse
                            return self.refuse("no overflow message for {s}", .{@tagName(op)}));
                    }
                }
                try self.w().writeAll(")");
            },
            .sign => {
                if (args.len != 1) return self.refuse("{s} arity {d}", .{ @tagName(op), args.len });
                const layout_idx = self.store().getLocal(GuardedList.at(args, 0)).layout_idx;
                if (!operand.isInt() and operand != .dec and operand != .f32 and operand != .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                const stem: []const u8 = if (op == .num_negate or op == .num_negate_checked) "neg" else "abs";
                // decBinOp negates Dec with wrapping even in the checked form.
                const checked = (op == .num_negate_checked or op == .num_abs_checked) and
                    !(operand == .dec and op == .num_negate_checked);
                const message: ?[]const u8 = if (checked)
                    CheckedArithmetic.overflowMessageForLayout(op, layout_idx) orelse
                        return self.refuse("no overflow message for {s}", .{@tagName(op)})
                else
                    null;
                try self.w().print("rt.{s}_{s}_{s}(", .{ stem, if (checked) "checked" else "wrap", operand.numName().? });
                try self.emitArgs(span);
                if (message) |text| {
                    try self.w().writeAll(", ");
                    try emitLuaString(self.w(), text);
                }
                try self.w().writeAll(")");
            },
            .runtime_call, .runtime_predicate => {
                if (lowerings.get(op) == .runtime_predicate and self.reprOfLocal(target) != .bool) {
                    return self.refuse("{s} into {s}", .{ @tagName(op), @tagName(self.reprOfLocal(target)) });
                }
                try self.w().print("rt.{s}(", .{@tagName(op)});
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .conversion => try self.emitConversion(op, span),
            .num_parse => try self.emitNumParse(op, span, target),
            .str_from_utf8 => try self.emitStrFromUtf8(span, target),
            .hasher => try self.emitHasher(op, span, target),
            .math => {
                if (operand != .dec and operand != .f32 and operand != .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                try self.w().print("rt.{s}_{s}(", .{ @tagName(op)[4..], operand.numName().? });
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .num_order => {
                if (operand.numName() == null) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (self.layoutTag(self.layoutOfLocal(target)) != .tag_union) return self.refuse("compare into {s}", .{@tagName(self.layoutTag(self.layoutOfLocal(target)))});
                if (operand.isWide()) {
                    try self.w().print("{{rt.order_cmp(rt.cmp_{s}(", .{operand.numName().?});
                    try self.emitArgs(span);
                    try self.w().writeAll("))}");
                } else {
                    try self.w().writeAll("{rt.order(");
                    try self.emitArgs(span);
                    try self.w().writeAll(")}");
                }
            },
            .identity => try self.emitArgs(span),
            .box => try self.emitBoxOp(op, GuardedList.at(args, 0), target),
            .float_arith => {
                if (operand != .f32 and operand != .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (args.len != 2) return self.refuse("{s} arity {d}", .{ @tagName(op), args.len });
                try self.w().writeAll(if (operand == .f32) "rt.f32(" else "(");
                try self.emitLocal(GuardedList.at(args, 0));
                try self.w().writeAll(if (op == .num_float_add) " + " else if (op == .num_float_sub) " - " else " * ");
                try self.emitLocal(GuardedList.at(args, 1));
                try self.w().writeAll(")");
            },
            .float_unary => {
                if (op == .num_sqrt and operand == .dec) {
                    try self.w().writeAll("rt.sqrt_dec(");
                    try self.emitArgs(span);
                    try self.w().writeAll(")");
                    return;
                }
                if (operand != .f32 and operand != .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                const stem: []const u8 = if (op == .num_floor) "floor" else if (op == .num_ceiling) "ceil" else "sqrt";
                try self.w().print("rt.{s}_{s}(", .{ stem, @tagName(operand) });
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .from_le_bytes => {
                const result = self.reprOfLocal(target);
                if (!result.isInt()) return self.refuse("from_le_bytes into {s}", .{@tagName(result)});
                try self.w().print("rt.from_le_bytes_{s}(", .{result.numName().?});
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .num_to_str => {
                const n = operand.numName() orelse return self.refuse("num_to_str on {s}", .{@tagName(operand)});
                try self.w().print("rt.{s}_to_str(", .{n});
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .bits => {
                if (!operand.isInt()) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                try self.w().print("rt.{s}_{s}(", .{ bitStem(op), operand.numName().? });
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .overflows => {
                if (!operand.isInt()) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                if (self.reprOfLocal(target) != .bool) return self.refuse("{s} into {s}", .{ @tagName(op), @tagName(self.reprOfLocal(target)) });
                try self.w().print("rt.{s}_overflows_{s}(", .{ arithName(op), operand.numName().? });
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
            .abs_diff => {
                if (args.len != 2) return self.refuse("{s} arity {d}", .{ @tagName(op), args.len });
                if (!operand.isInt() and operand != .dec and operand != .f32 and operand != .f64) return self.refuse("{s} on {s}", .{ @tagName(op), @tagName(operand) });
                try self.w().print("rt.abs_diff_{s}(", .{operand.numName().?});
                try self.emitArgs(span);
                try self.w().writeAll(")");
            },
        }
    }
};

/// The procedure a statement calls directly, if any.
fn callee(stmt: LIR.CFStmt) ?LIR.LirProcSpecId {
    return switch (stmt) {
        .assign_call => |call| call.proc,
        .assign_packed_erased_fn => |packed_fn| packed_fn.proc,
        .init_uninitialized,
        .assign_ref,
        .assign_literal,
        .assign_call_erased,
        .assign_boxy_desc_ref,
        .assign_boxy_dict_ref,
        .assign_boxy_box,
        .assign_boxy_reuse_box,
        .assign_boxy_unbox,
        .assign_boxy_adapt,
        .assign_boxy_inspect,
        .assign_boxy_tag,
        .assign_boxy_tag_payload,
        .boxy_tag_match,
        .assign_call_dict,
        .assign_low_level,
        .assign_list,
        .assign_struct,
        .assign_tag,
        .store_struct,
        .store_tag,
        .set_local,
        .debug,
        .expect,
        .expect_err,
        .runtime_error,
        .comptime_exhaustiveness_failed,
        .comptime_branch_taken,
        .incref,
        .decref,
        .decref_if_initialized,
        .free,
        .switch_stmt,
        .switch_initialized_payload,
        .str_match,
        .str_match_set,
        .loop_continue,
        .loop_break,
        .join,
        .jump,
        .ret,
        .crash,
        => null,
    };
}

/// Whether `value` is representable in the integer representation. u64
/// literals may arrive as their i64 bit pattern, so both readings are accepted.
fn fitsRepr(value: i128, repr: Repr) bool {
    return switch (repr) {
        .u8 => value >= 0 and value <= std.math.maxInt(u8),
        .i8 => value >= std.math.minInt(i8) and value <= std.math.maxInt(i8),
        .u16 => value >= 0 and value <= std.math.maxInt(u16),
        .i16 => value >= std.math.minInt(i16) and value <= std.math.maxInt(i16),
        .u32 => value >= 0 and value <= std.math.maxInt(u32),
        .i32 => value >= std.math.minInt(i32) and value <= std.math.maxInt(i32),
        .i64 => value >= std.math.minInt(i64) and value <= std.math.maxInt(i64),
        .u64 => value >= std.math.minInt(i64) and value <= std.math.maxInt(u64),
        // A U128 literal arrives as its I128 bit pattern.
        .i128, .u128 => true,
        // Dec values come only from `dec_literal`, already scaled.
        .bool, .str, .zst, .dec, .f32, .f64, .other => false,
    };
}

/// Write a float literal as Lua source that parses to exactly `v`: Zig's
/// shortest round-trip scientific form, with explicit expressions for the
/// infinities, NaN and negative zero. An F32 literal is widened exactly.
fn emitFloatLiteral(out: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(v)) return out.writeAll("(0/0)");
    if (std.math.isInf(v)) return out.writeAll(if (v > 0) "(1/0)" else "(-1/0)");
    if (v == 0 and std.math.signbit(v)) return out.writeAll("rt.NEG_ZERO");
    try out.print("({e})", .{v});
}

/// Write a 128-bit bit pattern as a table literal of eight 16-bit limbs, least
/// significant first, the representation `int128.lua` operates on. A table
/// constructor compiles to one TDUP; a vararg constructor call does not trace.
fn emitWideLiteral(out: *std.Io.Writer, value: i128) std.Io.Writer.Error!void {
    var bits: u128 = @bitCast(value);
    try out.writeAll("{");
    for (0..8) |i| {
        if (i != 0) try out.writeAll(", ");
        try out.print("{d}", .{@as(u16, @truncate(bits))});
        bits >>= 16;
    }
    try out.writeAll("}");
}

/// Runtime helper stem for an arithmetic op (`add`, `sub`, `mul`).
fn arithName(op: LowLevel) []const u8 {
    const name = @tagName(op);
    inline for (.{ "add", "sub", "mul" }) |stem| {
        if (std.mem.find(u8, name, "_" ++ stem ++ "_") != null) return stem;
    }
    unreachable; // only arithmetic ops reach here through `lowerings`
}

/// Runtime helper stem for a bit operation (runtime.lua "Bit operations").
fn bitStem(op: LowLevel) []const u8 {
    if (op == .num_shift_left_by) return "shl";
    if (op == .num_shift_right_by) return "shr";
    if (op == .num_shift_right_zf_by) return "shr_zf";
    if (op == .num_bitwise_and) return "band";
    if (op == .num_bitwise_or) return "bor";
    if (op == .num_bitwise_xor) return "bxor";
    if (op == .num_bitwise_not) return "bnot";
    if (op == .num_count_one_bits) return "popcount";
    if (op == .num_count_leading_zero_bits) return "clz";
    return "ctz";
}

/// Runtime helper stem for a division-family op: Roc's `//` on integers
/// truncates, so `num_div_by` and `num_div_trunc_by` share `div_trunc`.
fn divisionStem(op: LowLevel) []const u8 {
    if (op == .num_rem_by or op == .num_rem_by_checked) return "rem";
    if (op == .num_mod_by or op == .num_mod_by_checked) return "mod";
    return "div_trunc";
}

fn compareOperator(op: LowLevel) []const u8 {
    if (op == .num_is_eq) return " == ";
    if (op == .num_is_lt) return " < ";
    if (op == .num_is_lte) return " <= ";
    if (op == .num_is_gt) return " > ";
    if (op == .num_is_gte) return " >= ";
    unreachable; // only comparison ops reach here through `lowerings`
}

/// Write `bytes` as a Lua string literal. Printable ASCII passes through;
/// every other byte (including quotes, backslash and UTF-8 continuation
/// bytes) becomes a three-digit decimal escape, so the literal is exact.
fn emitLuaString(out: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    for (bytes) |byte| {
        if (byte >= 0x20 and byte < 0x7f and byte != '"' and byte != '\\') {
            try out.writeByte(byte);
        } else {
            try out.print("\\{d:0>3}", .{byte});
        }
    }
    try out.writeByte('"');
}

test "Lua string literals escape every non-printable byte exactly" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try emitLuaString(&buffer.writer, "a\"b\\c\n\x00\xc3\xa9");
    try std.testing.expectEqualStrings("\"a\\034b\\092c\\010\\000\\195\\169\"", buffer.written());
}

test "every LowLevel op defaults to unsupported unless listed" {
    try std.testing.expectEqual(Lowering.unsupported, lowerings.get(.list_append_unsafe));
    try std.testing.expectEqual(Lowering.checked_arith, lowerings.get(.num_int_add_crash_on_overflow));
    try std.testing.expectEqual(Lowering.wrapping_arith, lowerings.get(.num_int_mul_proven_cannot_overflow));
}

test "wide literals are eight 16-bit limbs, least significant first" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try emitWideLiteral(&out, 1_000_000_000_000_000_000);
    try std.testing.expectEqualStrings("{0, 42852, 46771, 3552, 0, 0, 0, 0}", out.buffered());
    out = .fixed(&buf);
    try emitWideLiteral(&out, -1);
    try std.testing.expectEqualStrings("{65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}", out.buffered());
}

test "float literals are exact Lua numbers" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try emitFloatLiteral(&out, 0.1);
    try std.testing.expectEqualStrings("(1e-1)", out.buffered());
    out = .fixed(&buf);
    try emitFloatLiteral(&out, -0.0);
    try std.testing.expectEqualStrings("rt.NEG_ZERO", out.buffered());
    out = .fixed(&buf);
    try emitFloatLiteral(&out, @as(f32, 0.1));
    try std.testing.expectEqualStrings("(1.0000000149011612e-1)", out.buffered());
}

/// Runtime operations that accept Str views (see runtime.lua "Strings");
/// every other operation receives its Str operands as Lua strings.
const view_aware_str_ops = [_]LowLevel{ .str_concat, .str_count_utf8_bytes, .str_is_eq };

fn viewAwareStrOp(op: LowLevel) bool {
    return std.mem.findScalar(LowLevel, &view_aware_str_ops, op) != null;
}
