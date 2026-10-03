//! Reference vectors for the LuaJIT runtime's 128-bit and Dec arithmetic.
//!
//! Writes one line per case to stdout: `<op> <a> <b> <expected>`, where
//! operands and results are decimal (I128 and Dec as signed bit patterns,
//! U128 unsigned) and `<expected>` is `crash` when the operation must crash.
//! Expectations come from upstream's Zig builtins (`RocDec.mulWithOverflow`,
//! `RocDec.format_to_buf`) and Zig's native overflow-checked i128/u128/u256
//! arithmetic, which share no code with the Lua limb implementation under test.
//! Dec division is computed from `RocDec.div`'s documented rule with native u256
//! arithmetic, because the builtin's crash hook must not return.
//!
//! Inputs are boundary values plus seeded random values of random bit length,
//! so runs are reproducible: `luajit-numeric-vectors [seed] [count]`.

const std = @import("std");
const builtins = @import("builtins");
const CoreCtx = @import("ctx").CoreCtx;

const RocDec = builtins.dec.RocDec;
const i128h = builtins.compiler_rt_128;

const edge_i128 = [_]i128{
    0,                           1,                           -1,                                  2,                         -2,
    10,                          std.math.maxInt(i128),       std.math.minInt(i128),               std.math.maxInt(i128) - 1, std.math.minInt(i128) + 1,
    std.math.maxInt(i64),        std.math.minInt(i64),        1 << 63,                             (1 << 64) - 1,             1 << 64,
    RocDec.one_point_zero_i128,  -RocDec.one_point_zero_i128, 5 * RocDec.one_point_zero_i128 / 10, 1 << 126,                  -(1 << 126),
    123_456_789_000_000_000_000,
};

fn randomI128(rng: std.Random) i128 {
    const bits = rng.intRangeAtMost(u8, 0, 127);
    var mag: u128 = rng.int(u128);
    mag = if (bits == 0) 0 else mag >> @intCast(128 - @as(u16, bits));
    const v: i128 = @intCast(mag);
    return if (rng.boolean()) -v else v;
}

fn randomU128(rng: std.Random) u128 {
    const bits = rng.intRangeAtMost(u8, 0, 128);
    if (bits == 0) return 0;
    return rng.int(u128) >> @intCast(128 - @as(u16, bits));
}

fn line(out: *std.Io.Writer, op: []const u8, a: anytype, b: anytype, expected: anytype) std.Io.Writer.Error!void {
    try out.print("{s} {d} {d} ", .{ op, a, b });
    if (expected) |value| try out.print("{d}\n", .{value}) else try out.writeAll("crash\n");
}

fn decDiv(a: i128, b: i128) ?i128 {
    if (b == 0) return null;
    if (a == 0) return 0;
    const negative = (a < 0) != (b < 0);
    const num: u256 = @as(u256, @abs(a)) * @as(u256, @intCast(RocDec.one_point_zero_i128));
    const q: u256 = num / @as(u256, @abs(b));
    if (negative) {
        if (q > (@as(u256, 1) << 127)) return null;
        return @bitCast(@as(u128, @truncate(0 -% q)));
    }
    if (q > std.math.maxInt(i128)) return null;
    return @intCast(q);
}

fn emitI128Pair(out: *std.Io.Writer, a: i128, b: i128) std.Io.Writer.Error!void {
    try line(out, "add_i128", a, b, blk: {
        const r = @addWithOverflow(a, b);
        break :blk if (r[1] != 0) null else r[0];
    });
    try line(out, "sub_i128", a, b, blk: {
        const r = @subWithOverflow(a, b);
        break :blk if (r[1] != 0) null else r[0];
    });
    try line(out, "mul_i128", a, b, blk: {
        const r = @mulWithOverflow(a, b);
        break :blk if (r[1] != 0) null else r[0];
    });
    try line(out, "mulwrap_i128", a, b, @as(?i128, a *% b));
    try line(out, "cmp_i128", a, b, @as(?i8, if (a < b) -1 else if (a > b) 1 else 0));
    const m = RocDec.mulWithOverflow(.{ .num = a }, .{ .num = b });
    try line(out, "dec_mul", a, b, if (m.has_overflowed) null else @as(?i128, m.value.num));
    try line(out, "dec_div", a, b, decDiv(a, b));
}

fn emitU128Pair(out: *std.Io.Writer, a: u128, b: u128) std.Io.Writer.Error!void {
    try line(out, "add_u128", a, b, blk: {
        const r = @addWithOverflow(a, b);
        break :blk if (r[1] != 0) null else r[0];
    });
    try line(out, "sub_u128", a, b, blk: {
        const r = @subWithOverflow(a, b);
        break :blk if (r[1] != 0) null else r[0];
    });
    try line(out, "mul_u128", a, b, blk: {
        const r = @mulWithOverflow(a, b);
        break :blk if (r[1] != 0) null else r[0];
    });
    try line(out, "cmp_u128", a, b, @as(?i8, if (a < b) -1 else if (a > b) 1 else 0));
}

fn emitFormat(out: *std.Io.Writer, a: i128) std.Io.Writer.Error!void {
    var buf: [RocDec.max_str_length]u8 = undefined;
    const text = (RocDec{ .num = a }).format_to_buf(&buf);
    try out.print("dec_to_str {d} 0 {s}\n", .{ a, text });
    try out.print("i128_to_str {d} 0 {d}\n", .{ a, a });
}

/// Result of an integer operation as upstream's interpreter defines it
/// (`intBinOp` in src/eval/interpreter.zig): a value, or a crash for a zero
/// denominator or an overflow in the checked forms.
fn Outcome(comptime T: type) type {
    return union(enum) { value: T, zero, overflow };
}

fn outcomeLine(comptime T: type, out: *std.Io.Writer, op: []const u8, a: T, b: T, r: Outcome(T)) std.Io.Writer.Error!void {
    try out.print("{s}_{s} {d} {d} ", .{ op, @typeName(T), a, b });
    switch (r) {
        .value => |v| try out.print("{d}\n", .{v}),
        .zero => try out.writeAll("crash:zero\n"),
        .overflow => try out.writeAll("crash:overflow\n"),
    }
}

fn minDivOverflow(comptime T: type, a: T, b: T) bool {
    if (@typeInfo(T).int.signedness != .signed) return false;
    return a == std.math.minInt(T) and b == -1;
}

/// Division-family and sign vectors for one integer width.
fn emitIntDivPair(comptime T: type, out: *std.Io.Writer, a: T, b: T) std.Io.Writer.Error!void {
    const O = Outcome(T);
    const signed = @typeInfo(T).int.signedness == .signed;
    const special = minDivOverflow(T, a, b);
    try outcomeLine(T, out, "div_trunc", a, b, if (b == 0) O{ .value = 0 } else if (special) O{ .value = a } else O{ .value = @divTrunc(a, b) });
    try outcomeLine(T, out, "div_trunc_checked", a, b, if (b == 0) O.zero else if (special) O.overflow else O{ .value = @divTrunc(a, b) });
    try outcomeLine(T, out, "rem", a, b, if (b == 0 or special) O{ .value = 0 } else O{ .value = @rem(a, b) });
    try outcomeLine(T, out, "rem_checked", a, b, if (b == 0) O.zero else if (special) O{ .value = 0 } else O{ .value = @rem(a, b) });
    try outcomeLine(T, out, "mod", a, b, if (b == 0 or special) O{ .value = 0 } else O{ .value = @mod(a, b) });
    try outcomeLine(T, out, "mod_checked", a, b, if (b == 0) O.zero else if (special) O{ .value = 0 } else O{ .value = @mod(a, b) });
    // Roc's abs_diff returns the unsigned type of the same width: the
    // interpreter writes the wrapped difference bits into an unsigned result.
    const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
    const distance: U = @bitCast(if (a > b) a -% b else b -% a);
    try out.print("abs_diff_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, distance });
    const neg = @subWithOverflow(@as(T, 0), a);
    try outcomeLine(T, out, "neg_wrap", a, 0, O{ .value = neg[0] });
    try outcomeLine(T, out, "neg_checked", a, 0, if (neg[1] != 0) O.overflow else O{ .value = neg[0] });
    const negative = signed and a < 0;
    try outcomeLine(T, out, "abs_wrap", a, 0, O{ .value = if (negative) neg[0] else a });
    try outcomeLine(T, out, "abs_checked", a, 0, if (negative and neg[1] != 0) O.overflow else O{ .value = if (negative) neg[0] else a });
}

fn randomInt(comptime T: type, rng: std.Random) T {
    const bits = @typeInfo(T).int.bits;
    const U = std.meta.Int(.unsigned, bits);
    const width = rng.intRangeAtMost(u16, 0, bits);
    const raw: U = if (width == 0) 0 else rng.int(U) >> @intCast(bits - width);
    return @bitCast(raw);
}

fn emitIntDivFamily(comptime T: type, out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    const signed = @typeInfo(T).int.signedness == .signed;
    const edges = [_]T{
        0,                     1,                      2,                       7,
        std.math.maxInt(T),    std.math.maxInt(T) - 1, std.math.minInt(T),      std.math.minInt(T) +% 1,
        if (signed) -1 else 3, if (signed) -2 else 10, if (signed) -7 else 100, std.math.maxInt(T) / 2,
    };
    for (edges) |a| for (edges) |b| try emitIntDivPair(T, out, a, b);
    for (0..count) |_| try emitIntDivPair(T, out, randomInt(T, rng), randomInt(T, rng));
}

/// Dec truncating division, remainder, modulo, negation and absolute value,
/// following `RocDec.div`+`trunc`, `rem`, `mod` and the interpreter's
/// `decBinOp`. `crash` covers every Dec crash; messages are checked by the
/// differential runner.
fn emitDecDivPair(out: *std.Io.Writer, a: i128, b: i128) std.Io.Writer.Error!void {
    const one = RocDec.one_point_zero_i128;
    try line(out, "dec_div_trunc", a, b, if (decDiv(a, b)) |q| @as(?i128, q - @rem(q, one)) else null);
    try line(out, "dec_rem", a, b, if (b == 0) null else @as(?i128, i128h.rem_i128(a, b)));
    try line(out, "dec_mod", a, b, if (b == 0) null else blk: {
        const r = i128h.rem_i128(a, b);
        break :blk @as(?i128, if (r != 0 and ((r > 0) != (b > 0))) r +% b else r);
    });
    try line(out, "neg_wrap_dec", a, 0, @as(?i128, 0 -% a));
    try line(out, "abs_wrap_dec", a, 0, @as(?i128, if (a < 0) 0 -% a else a));
    try line(out, "abs_checked_dec", a, 0, if (a == std.math.minInt(i128)) null else @as(?i128, if (a < 0) -a else a));
}

/// Integer conversion vectors: `cvt_<src>_<dst> a 0 r` is the wrap result
/// (low bits of the sign- or zero-extended value), `cvttry_<src>_<dst> a 0 r`
/// the checked result or `fail` (`std.math.cast`), as the interpreter's
/// numTruncate/numTruncateWiden/numTry compute them.
fn emitConversions(comptime Src: type, out: *std.Io.Writer, rng: std.Random) std.Io.Writer.Error!void {
    const kinds = .{ i8, u8, i16, u16, i32, u32, i64, u64, i128, u128 };
    const edges = [_]Src{ 0, 1, std.math.maxInt(Src), std.math.minInt(Src), std.math.maxInt(Src) - 1, std.math.minInt(Src) +% 1 };
    var values: [64]Src = undefined;
    for (edges, 0..) |e, i| values[i] = e;
    for (edges.len..values.len) |i| values[i] = randomInt(Src, rng);
    inline for (kinds) |Dst| {
        for (values) |a| {
            const Wide = i256;
            const wide: Wide = a;
            const UD = std.meta.Int(.unsigned, @typeInfo(Dst).int.bits);
            const wrapped: Dst = @bitCast(@as(UD, @truncate(@as(u256, @bitCast(wide)))));
            try out.print("cvt_{s}_{s} {d} 0 {d}\n", .{ @typeName(Src), @typeName(Dst), a, wrapped });
            if (std.math.cast(Dst, a)) |v| {
                try out.print("cvttry_{s}_{s} {d} 0 {d}\n", .{ @typeName(Src), @typeName(Dst), a, v });
            } else {
                try out.print("cvttry_{s}_{s} {d} 0 fail\n", .{ @typeName(Src), @typeName(Dst), a });
            }
        }
    }
    // Int to Dec (exact: wrapping multiply by 10^18; try: fromWholeInt).
    for (values) |a| {
        const as_i128: i128 = @truncate(@as(i256, a));
        try out.print("cvtdec_{s} {d} 0 {d}\n", .{ @typeName(Src), a, as_i128 *% RocDec.one_point_zero_i128 });
        const fits = std.math.cast(i128, a);
        if (fits) |v| {
            if (RocDec.fromWholeInt(v)) |d| {
                try out.print("cvtdectry_{s} {d} 0 {d}\n", .{ @typeName(Src), a, d.num });
                continue;
            }
        }
        try out.print("cvtdectry_{s} {d} 0 fail\n", .{ @typeName(Src), a });
    }
}

/// Dec to integer vectors (builtins/dec.zig toIntWrap / toIntTry).
fn emitDecToInt(out: *std.Io.Writer, d: i128) std.Io.Writer.Error!void {
    inline for (.{ i8, u8, i16, u16, i32, u32, i64, u64, i128, u128 }) |Dst| {
        try out.print("cvtfromdec_{s} {d} 0 {d}\n", .{ @typeName(Dst), d, builtins.dec.toIntWrap(Dst, .{ .num = d }) });
        if (builtins.dec.toIntTry(Dst, .{ .num = d })) |v| {
            try out.print("cvtfromdectry_{s} {d} 0 {d}\n", .{ @typeName(Dst), d, v });
        } else {
            try out.print("cvtfromdectry_{s} {d} 0 fail\n", .{ @typeName(Dst), d });
        }
    }
}

/// Bit operation vectors, as the interpreter's shiftOp/bitwiseOp/bitCount
/// compute them: shift counts are taken modulo the width; `shr` is arithmetic
/// for signed types; counts are U8. Also the `*_overflows` predicates.
fn emitBitOps(comptime T: type, out: *std.Io.Writer, rng: std.Random) std.Io.Writer.Error!void {
    const bits = @typeInfo(T).int.bits;
    const U = std.meta.Int(.unsigned, bits);
    const Shift = std.math.Log2Int(T);
    const edges = [_]T{ 0, 1, 2, std.math.maxInt(T), std.math.minInt(T), std.math.minInt(T) +% 1, std.math.maxInt(T) - 1 };
    var values: [40]T = undefined;
    for (edges, 0..) |e, i| values[i] = e;
    for (edges.len..values.len) |i| values[i] = randomInt(T, rng);
    for (values) |a| {
        for ([_]u8{ 0, 1, 3, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 129, 200, 255 }) |amount| {
            const s: Shift = @intCast(amount % bits);
            try out.print("shl_{s} {d} {d} {d}\n", .{ @typeName(T), a, amount, a << s });
            try out.print("shr_{s} {d} {d} {d}\n", .{ @typeName(T), a, amount, a >> s });
            try out.print("shr_zf_{s} {d} {d} {d}\n", .{ @typeName(T), a, amount, @as(T, @bitCast(@as(U, @bitCast(a)) >> s)) });
        }
        try out.print("bnot_{s} {d} 0 {d}\n", .{ @typeName(T), a, ~a });
        try out.print("popcount_{s} {d} 0 {d}\n", .{ @typeName(T), a, @popCount(a) });
        try out.print("clz_{s} {d} 0 {d}\n", .{ @typeName(T), a, @clz(a) });
        try out.print("ctz_{s} {d} 0 {d}\n", .{ @typeName(T), a, @ctz(a) });
        for (values) |b| {
            try out.print("band_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, a & b });
            try out.print("bor_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, a | b });
            try out.print("bxor_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, a ^ b });
            try out.print("add_overflows_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, @addWithOverflow(a, b)[1] });
            try out.print("sub_overflows_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, @subWithOverflow(a, b)[1] });
            try out.print("mul_overflows_{s} {d} {d} {d}\n", .{ @typeName(T), a, b, @mulWithOverflow(a, b)[1] });
        }
    }
}

/// Float formatting vectors from upstream's formatter (compiler_rt_128
/// f64_to_str / f32_to_str over vendor/ryu.zig): `f64str <bits> 0 <text>`.
fn emitFloatFormats(out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    var buf: [400]u8 = undefined;
    const f64_edges = [_]u64{
        0,                  0x8000000000000000, 1,                  0x000fffffffffffff, 0x0010000000000000,
        0x7fefffffffffffff, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x3ff0000000000000,
        0x3fb999999999999a, 0x4415af1d78b58c40, 0x4340000000000001, 0x3fe0000000000000, 0x44b52d02c7e14af6,
    };
    for (f64_edges) |b| try out.print("f64str {d} 0 {s}\n", .{ b, builtins.compiler_rt_128.f64_to_str(&buf, @bitCast(b)) });
    // Every power of two and its neighbours exercises the asymmetric interval.
    for (0..2047) |e| {
        const b: u64 = @as(u64, e) << 52;
        for ([_]u64{ b, b +% 1, b -% 1 }) |v| {
            try out.print("f64str {d} 0 {s}\n", .{ v, builtins.compiler_rt_128.f64_to_str(&buf, @bitCast(v)) });
        }
    }
    for (0..count * 4) |_| {
        const b = rng.int(u64);
        try out.print("f64str {d} 0 {s}\n", .{ b, builtins.compiler_rt_128.f64_to_str(&buf, @bitCast(b)) });
        // Short decimals (k / 10^j) are the common case in programs.
        const short: f64 = @as(f64, @floatFromInt(rng.intRangeAtMost(i32, -100000, 100000))) / std.math.pow(f64, 10, @floatFromInt(rng.intRangeAtMost(u8, 0, 8)));
        try out.print("f64str {d} 0 {s}\n", .{ @as(u64, @bitCast(short)), builtins.compiler_rt_128.f64_to_str(&buf, short) });
    }
    for (0..255) |e| {
        const b: u32 = @as(u32, @intCast(e)) << 23;
        for ([_]u32{ b, b +% 1, b -% 1 }) |v| {
            try out.print("f32str {d} 0 {s}\n", .{ v, builtins.compiler_rt_128.f32_to_str(&buf, @bitCast(v)) });
        }
    }
    for (0..count * 4) |_| {
        const b = rng.int(u32);
        try out.print("f32str {d} 0 {s}\n", .{ b, builtins.compiler_rt_128.f32_to_str(&buf, @bitCast(b)) });
    }
}

fn f64Bits(x: f64) u64 {
    return builtins.float_bits.normalizeF64NanBits(@bitCast(x));
}
fn f32Bits(x: f32) u32 {
    return builtins.float_bits.normalizeF32NanBits(@bitCast(x));
}

/// Float conversion and F32 arithmetic vectors. Floats travel as bit patterns
/// (NaN normalized, as Roc's to_bits does): int->float (@floatFromInt),
/// float->int (numeric_conversions floatToIntWrap / floatToIntTry), F64->F32,
/// Dec->float (RocDec.toF64 / toF32), and F32 + - * / sqrt (one rounding).
fn emitFloatConversions(out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    const kinds = .{ i8, u8, i16, u16, i32, u32, i64, u64, i128, u128 };
    inline for (kinds) |Src| {
        for (0..64) |_| {
            const a = randomInt(Src, rng);
            try out.print("itof_{s}_f64 {d} 0 {d}\n", .{ @typeName(Src), a, f64Bits(@floatFromInt(a)) });
            try out.print("itof_{s}_f32 {d} 0 {d}\n", .{ @typeName(Src), a, f32Bits(@floatFromInt(a)) });
        }
    }
    var floats64: [256]f64 = undefined;
    for (&floats64, 0..) |*f, i| {
        f.* = switch (i % 4) {
            0 => @bitCast(rng.int(u64)),
            1 => @as(f64, @floatFromInt(rng.int(i64))) / @as(f64, @floatFromInt(@as(u64, 1) << @intCast(rng.intRangeAtMost(u6, 0, 40)))),
            2 => @as(f64, @floatFromInt(randomInt(i128, rng))),
            else => @as(f64, @floatFromInt(rng.intRangeAtMost(i32, -1000, 1000))) + 0.5,
        };
    }
    for (floats64) |x| {
        inline for (kinds) |Dst| {
            try out.print("ftoi_f64_{s} {d} 0 {d}\n", .{ @typeName(Dst), f64Bits(x), builtins.numeric_conversions.floatToIntWrap(f64, Dst, x) });
            const xs: f32 = @floatCast(x);
            try out.print("ftoi_f32_{s} {d} 0 {d}\n", .{ @typeName(Dst), f32Bits(xs), builtins.numeric_conversions.floatToIntWrap(f32, Dst, xs) });
            if (builtins.numeric_conversions.floatToIntTry(f64, Dst, x)) |v| {
                try out.print("ftoitry_f64_{s} {d} 0 {d}\n", .{ @typeName(Dst), f64Bits(x), v });
            } else try out.print("ftoitry_f64_{s} {d} 0 fail\n", .{ @typeName(Dst), f64Bits(x) });
        }
        try out.print("f64tof32 {d} 0 {d}\n", .{ f64Bits(x), f32Bits(@floatCast(x)) });
        if (builtins.numeric_conversions.f64FitsF32(x)) {
            try out.print("f64tof32try {d} 0 {d}\n", .{ f64Bits(x), f32Bits(@floatCast(x)) });
        } else try out.print("f64tof32try {d} 0 fail\n", .{f64Bits(x)});
    }
    for (0..count) |_| {
        const d = randomI128(rng);
        try out.print("dectof64 {d} 0 {d}\n", .{ d, f64Bits((RocDec{ .num = d }).toF64()) });
        try out.print("dectof32 {d} 0 {d}\n", .{ d, f32Bits(builtins.dec.toF32(.{ .num = d })) });
        const a: f32 = @bitCast(rng.int(u32));
        const b: f32 = @bitCast(rng.int(u32));
        const ab = f32Bits(a);
        const bb = f32Bits(b);
        try out.print("f32add {d} {d} {d}\n", .{ ab, bb, f32Bits(a + b) });
        try out.print("f32sub {d} {d} {d}\n", .{ ab, bb, f32Bits(a - b) });
        try out.print("f32mul {d} {d} {d}\n", .{ ab, bb, f32Bits(a * b) });
        try out.print("f32div {d} {d} {d}\n", .{ ab, bb, f32Bits(a / b) });
        try out.print("f32sqrt {d} 0 {d}\n", .{ ab, f32Bits(@sqrt(a)) });
    }
}

/// Comparator state for the fluxsort vectors: element ids index `vals`; the
/// mode picks a total preorder or a hostile, self-contradicting answer.
const SortCtx = struct {
    vals: []const u64,
    mode: u8,
    seed: u64,
    calls: u64 = 0,
    trace: u64 = 0,
};

const sort_hash_mod = 1_000_000_007;

/// Roc Ordering discriminants as sort.zig reads them: After 0, Before 1, Same 2.
fn orderBy(a: u64, b: u64) u8 {
    return if (a > b) 0 else if (a < b) 1 else 2;
}

/// Compare two u32 element ids, recording the call in a rolling trace hash.
fn sortVectorCompare(data: ?[*]u8, a_ptr: ?[*]u8, b_ptr: ?[*]u8) callconv(.c) u8 {
    const ctx: *SortCtx = @ptrCast(@alignCast(data.?));
    const a: u64 = std.mem.readInt(u32, a_ptr.?[0..4], .little);
    const b: u64 = std.mem.readInt(u32, b_ptr.?[0..4], .little);
    ctx.trace = (ctx.trace * 31 + a * 1009 + b + 1) % sort_hash_mod;
    ctx.calls += 1;
    return switch (ctx.mode) {
        0 => orderBy(ctx.vals[a], ctx.vals[b]),
        1 => orderBy(ctx.vals[a] % 7, ctx.vals[b] % 7),
        2 => @intCast(((a * 7919 + b * 104729 + ctx.seed * 15485863 + ctx.calls * 31) % 1000003) % 3),
        else => orderBy(ctx.vals[b], ctx.vals[a]),
    };
}

fn sortVectorCopy(dst: ?[*]u8, src: ?[*]u8, width: usize) callconv(.c) void {
    std.mem.copyForwards(u8, dst.?[0..width], src.?[0..width]);
}

/// Values for element ids 0..n-1 by input kind: ascending, descending, MINSTD
/// random with duplicates, sawtooth, and ascending with scattered inversions.
fn sortVectorValues(gpa: std.mem.Allocator, kind: u8, n: u64, seed: u64) std.mem.Allocator.Error![]u64 {
    const vals = try gpa.alloc(u64, n);
    var x: u64 = seed % 2147483646 + 1;
    for (vals, 0..) |*v, i| {
        v.* = switch (kind) {
            0 => i,
            1 => n - i,
            2 => blk: {
                x = x * 48271 % 2147483647;
                break :blk x % (n + 1);
            },
            3 => i % 37,
            else => if (i % 50 == 0) n - i else i,
        };
    }
    return vals;
}

/// Fluxsort vectors: `sort kind,mode,n,seed 0 calls:trace:out` replays the
/// whole comparison sequence; `sortout` (lists over 2048, where sort.zig's
/// median_of_cube_root samples from a stack-address offset) checks only the
/// output order, for total preorders.
fn emitSortVectors(out: *std.Io.Writer, gpa: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    var env = builtins.utils.TestEnv.init(gpa);
    defer env.deinit();
    const sizes_traced = [_]u64{ 400, 512, 777, 1024, 1500, 2048 };
    const sizes_output = [_]u64{ 2049, 3000, 5000, 10000 };
    var n: u64 = 0;
    while (n <= 300 + sizes_traced.len + sizes_output.len) : (n += 1) {
        const len: u64 = if (n <= 300) n else if (n - 301 < sizes_traced.len) sizes_traced[n - 301] else sizes_output[n - 301 - sizes_traced.len];
        const traced = len <= 2048;
        for (0..5) |kind| for (0..4) |mode| {
            if (!traced and mode == 2) continue;
            const seed = len * 5 + kind + mode * 1000;
            const vals = try sortVectorValues(gpa, @intCast(kind), len, seed);
            defer gpa.free(vals);
            const ids = try gpa.alloc(u32, len);
            defer gpa.free(ids);
            for (ids, 0..) |*id, i| id.* = @intCast(i);
            var ctx = SortCtx{ .vals = vals, .mode = @intCast(mode), .seed = seed };
            builtins.sort.fluxsort(@ptrCast(ids.ptr), len, &sortVectorCompare, @ptrCast(&ctx), false, null, @ptrCast(&builtins.utils.rcNone), 4, 4, &sortVectorCopy, env.getOps());
            var out_hash: u64 = 0;
            for (ids) |id| out_hash = (out_hash * 31 + id + 1) % sort_hash_mod;
            if (traced) {
                try out.print("sort {d},{d},{d},{d} 0 {d}:{d}:{d}\n", .{ kind, mode, len, seed, ctx.calls, ctx.trace, out_hash });
            } else {
                try out.print("sortout {d},{d},{d},{d} 0 {d}\n", .{ kind, mode, len, seed, out_hash });
            }
        };
    }
}

/// Strings for the numeric parsing vectors: grammar edge cases plus seeded
/// random strings over the characters the token grammars care about.
const parse_edge_strings = [_][]const u8{
    "",                                        "0",                                     "-0",                                      "+0",                                      "1",                                        "-1",
    "+",                                       "-",                                     "_",                                       "1_000",                                   "1__0",                                     "_1",
    "1_",                                      "1e3",                                   "1e-0",                                    "1e-1",                                    "0e999999999999999999999",                  "1e38",
    "1e39",                                    "255",                                   "256",                                     "-128",                                    "-129",                                     "127",
    "128",                                     "65535",                                 "65536",                                   "-32768",                                  "2147483647",                               "2147483648",
    "-2147483648",                             "4294967295",                            "4294967296",                              "9223372036854775807",                     "9223372036854775808",                      "-9223372036854775808",
    "18446744073709551615",                    "18446744073709551616",                  "170141183460469231731687303715884105727", "170141183460469231731687303715884105728", "-170141183460469231731687303715884105728", "340282366920938463463374607431768211455",
    "340282366920938463463374607431768211456", "0x",                                    "0x1F",                                    "0X1f",                                    "-0x80",                                    "0b1011",
    "0o777",                                   "0x_1",                                  "0x1_",                                    "0x1__2",                                  "0x1_2",                                    "0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
    "0x1g",                                    "1.5",                                   ".5",                                      "5.",                                      ".",                                        "1.2.3",
    "3.14159",                                 "-2.5e-3",                               "1e",                                      "1e+",                                     "1e+5",                                     "1E5",
    "1e5x",                                    "inf",                                   "-inf",                                    "Infinity",                                "INF",                                      "infinit",
    "nan",                                     "NaN",                                   "-nan",                                    "nanx",                                    "1e308",                                    "1.8e308",
    "1.7976931348623157e308",                  "1.7976931348623158e308",                "1.7976931348623159e308",                  "4.9e-324",                                "2.4703282292062327e-324",                  "2.4703282292062328e-324",
    "1e-400",                                  "3.4028235e38",                          "3.4028236e38",                            "1.4e-45",                                 "7.006492321624085e-46",                    "0x1p-1074",
    "0x1p-1075",                               "0x1.8p1",                               "0x.8p1",                                  "0x1.p4",                                  "0xp1",                                     "0x1p",
    "0x1.fffffffffffff8p1023",                 "0x1.fffffffffffffp1023",                "0x1_0p1_0",                               "1_0.5_5e1_0",                             "1._5",                                     "1_.5",
    "0.000000000000000000000000000000000001",  "123456789012345678.123456789012345678", "1.000000000000000000001",                 "99999999999999999999.999999999999999999", "0.1e-17",                                  "1e-18",
    "1e-19",                                   "100e-20",                               "-0.0",                                    " 1",                                      "1 ",
    "１",
    "0.30000000000000004441",                  "9007199254740993",                      "2.2250738585072011e-308",                 "2.2250738585072012e-308",                 "123456789012345678901234567890e-10",       "0x123456789abcdef0123456789p-40",
};

const parse_alphabet = "0123456789_.eE+-xXoObBpPaAfFinIty ";

/// One line per parse: `<op> <hex input> 0 <result>`. Results: from_str
/// `1:<value>` or `0`; prefix `<consumed>:<err>:<value>` (value 0 on error).
fn emitParseVectorsFor(out: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var hex_buf: [512]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{bytes}) catch unreachable;
    const h = if (bytes.len == 0) "-" else hex;
    inline for (.{ u8, i8, u16, i16, u32, i32, u64, i64, u128, i128 }) |T| {
        if (builtins.num.parseIntSlice(T, bytes)) |v| {
            try out.print("pint_{s} {s} 0 1:{d}\n", .{ @typeName(T), h, v });
        } else try out.print("pint_{s} {s} 0 0\n", .{ @typeName(T), h });
        const p = builtins.num.parseIntPrefix(T, bytes);
        try out.print("pintp_{s} {s} 0 {d}:{d}:{d}\n", .{ @typeName(T), h, p.consumed, p.errorcode, p.value });
    }
    if (if (bytes.len == 0) null else RocDec.fromNonemptySlice(bytes)) |d| {
        try out.print("pdec {s} 0 1:{d}\n", .{ h, d.num });
    } else try out.print("pdec {s} 0 0\n", .{h});
    const dp = builtins.dec.parsePrefix(bytes);
    try out.print("pdecp {s} 0 {d}:{d}:{d}\n", .{ h, dp.consumed, dp.errorcode, dp.value });
    if (builtins.num.parseFloatSlice(f64, bytes)) |v| {
        try out.print("pflt_f64 {s} 0 1:{d}\n", .{ h, f64Bits(v) });
    } else try out.print("pflt_f64 {s} 0 0\n", .{h});
    const f64p = builtins.num.parseFloatPrefix(f64, bytes);
    try out.print("pfltp_f64 {s} 0 {d}:{d}:{d}\n", .{ h, f64p.consumed, f64p.errorcode, f64Bits(f64p.value) });
    if (builtins.num.parseFloatSlice(f32, bytes)) |v| {
        try out.print("pflt_f32 {s} 0 1:{d}\n", .{ h, f32Bits(v) });
    } else try out.print("pflt_f32 {s} 0 0\n", .{h});
    const f32p = builtins.num.parseFloatPrefix(f32, bytes);
    try out.print("pfltp_f32 {s} 0 {d}:{d}:{d}\n", .{ h, f32p.consumed, f32p.errorcode, f32Bits(f32p.value) });
}

/// Numeric parsing vectors from upstream's parsers (num.zig, dec.zig and
/// vendor/parse_float): edge strings, random grammar soup, formatted random
/// floats and integers, and long digit strings.
fn emitParseVectors(out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    for (parse_edge_strings) |s| try emitParseVectorsFor(out, s);
    var buf: [200]u8 = undefined;
    for (0..count) |_| {
        const len = rng.uintLessThan(usize, 24);
        for (buf[0..len]) |*c| c.* = parse_alphabet[rng.uintLessThan(usize, parse_alphabet.len)];
        try emitParseVectorsFor(out, buf[0..len]);
    }
    for (0..count) |_| {
        const bits = rng.int(u64);
        const s = std.fmt.bufPrint(&buf, "{e}", .{@as(f64, @bitCast(bits))}) catch unreachable;
        try emitParseVectorsFor(out, s);
        const digits = rng.intRangeAtMost(usize, 1, 17);
        const s2 = std.fmt.bufPrint(&buf, "{d}e{d}", .{ rng.uintLessThan(u64, std.math.pow(u64, 10, digits)), rng.intRangeAtMost(i32, -340, 320) }) catch unreachable;
        try emitParseVectorsFor(out, s2);
        const s3 = std.fmt.bufPrint(&buf, "{d}", .{randomI128(rng)}) catch unreachable;
        try emitParseVectorsFor(out, s3);
        const s4 = std.fmt.bufPrint(&buf, "{d}.{d}", .{ rng.int(i64), rng.int(u64) }) catch unreachable;
        try emitParseVectorsFor(out, s4);
        const s5 = std.fmt.bufPrint(&buf, "0x{x}.{x}p{d}", .{ rng.int(u64), rng.int(u32), rng.intRangeAtMost(i32, -1100, 1050) }) catch unreachable;
        try emitParseVectorsFor(out, s5);
    }
    // Long digit strings (more than 19 significant digits) near halfway points.
    for (0..count / 4) |_| {
        const len = rng.intRangeAtMost(usize, 20, 120);
        for (buf[0..len]) |*c| c.* = '0' + @as(u8, @intCast(rng.uintLessThan(u8, 10)));
        buf[rng.uintLessThan(usize, len)] = '.';
        const exp = std.fmt.bufPrint(buf[len..], "e{d}", .{rng.intRangeAtMost(i32, -360, 330)}) catch unreachable;
        try emitParseVectorsFor(out, buf[0 .. len + exp.len]);
    }
}

/// UTF-8 vectors from builtins/str.zig: `utf8 <hex> 0 ok` or
/// `utf8 <hex> 0 err:<byte index>:<problem code>`, and
/// `utf8lossy <hex> 0 <hex of the lossy Str>` ("-" for empty).
fn emitUtf8VectorsFor(out: *std.Io.Writer, env: *builtins.utils.TestEnv, bytes: []u8) std.Io.Writer.Error!void {
    var hex_buf: [600]u8 = undefined;
    const h = if (bytes.len == 0) "-" else std.fmt.bufPrint(&hex_buf, "{x}", .{bytes}) catch unreachable;
    const ops = env.getOps();
    // A real allocation: fromUtf8 increfs the list it shares with its result.
    const list = builtins.list.RocList.fromSlice(u8, bytes, false, ops);
    const r = builtins.str.fromUtf8(list, .Immutable, ops);
    if (r.is_ok) {
        try out.print("utf8 {s} 0 ok\n", .{h});
    } else {
        try out.print("utf8 {s} 0 err:{d}:{d}\n", .{ h, r.byte_index, @intFromEnum(r.problem_code) });
    }
    const lossy = builtins.str.fromUtf8Lossy(list, ops);
    var lossy_buf: [2000]u8 = undefined;
    const lossy_bytes = lossy.asSlice();
    const lh = if (lossy_bytes.len == 0) "-" else std.fmt.bufPrint(&lossy_buf, "{x}", .{lossy_bytes}) catch unreachable;
    try out.print("utf8lossy {s} 0 {s}\n", .{ h, lh });
}

/// Byte strings mixing valid sequences of every length with truncations,
/// stray continuation bytes, overlong forms, surrogates and out-of-range
/// leads, plus fully random bytes.
fn emitUtf8Vectors(out: *std.Io.Writer, gpa: std.mem.Allocator, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    var env = builtins.utils.TestEnv.init(gpa);
    defer env.deinit();
    const pieces = [_][]const u8{
        "a",                "Z",                "\x00",             "\x7f",             "\xc2\xa9",         "\xdf\xbf", "\xe2\x82\xac", "\xef\xbf\xbd",
        "\xf0\x9f\x98\x80", "\xf4\x8f\xbf\xbf", "\x80",             "\xbf",             "\xc0\x80",         "\xc1\xbf", "\xe0\x80\x80", "\xe0\x9f\xbf",
        "\xed\xa0\x80",     "\xed\xbf\xbf",     "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\xf8",     "\xff",         "\xc2",
        "\xe2\x82",         "\xf0\x9f\x98",     "\xc2a",            "\xe2\x82a",        "\xf0\x9f\x98a",    "\xfe\xff", "\x80\x80\x80", "\xc0",
    };
    var buf: [256]u8 = undefined;
    for (pieces) |p| {
        @memcpy(buf[0..p.len], p);
        try emitUtf8VectorsFor(out, &env, buf[0..p.len]);
    }
    try emitUtf8VectorsFor(out, &env, buf[0..0]);
    for (0..count) |_| {
        var len: usize = 0;
        const parts = rng.uintLessThan(usize, 12);
        for (0..parts) |_| {
            const p = pieces[rng.uintLessThan(usize, pieces.len)];
            if (len + p.len > buf.len) break;
            @memcpy(buf[len..][0..p.len], p);
            len += p.len;
        }
        try emitUtf8VectorsFor(out, &env, buf[0..len]);
        const rlen = rng.uintLessThan(usize, 40);
        rng.bytes(buf[0..rlen]);
        try emitUtf8VectorsFor(out, &env, buf[0..rlen]);
    }
}

/// Dict/Set hasher vectors from builtins/hash.zig: `hwint_<domain>_<width>
/// <seed> <value> <state>`, `hwwide_<domain>` (U128 bits), `hwf32`/`hwf64`
/// (raw bits, NaN payloads and signed zeros included), `hwstr` (hex bytes),
/// `hfinish`.
fn emitHashVectors(out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    const H = builtins.hash;
    const domains = [_]struct { d: H.HasherDomain, w: u8 }{
        .{ .d = .bool, .w = 1 }, .{ .d = .u8, .w = 1 },  .{ .d = .i8, .w = 1 },  .{ .d = .u16, .w = 2 }, .{ .d = .i16, .w = 2 },
        .{ .d = .u32, .w = 4 },  .{ .d = .i32, .w = 4 }, .{ .d = .u64, .w = 8 }, .{ .d = .i64, .w = 8 },
    };
    var buf: [100]u8 = undefined;
    var hex_buf: [220]u8 = undefined;
    for (0..count) |_| {
        const seed = rng.int(u64);
        for (domains) |dw| {
            const mask: u64 = if (dw.w == 8) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(8 * @as(u32, dw.w))) - 1;
            const v = if (dw.d == .bool) rng.uintLessThan(u64, 2) else rng.int(u64) & mask;
            try out.print("hwint_{d}_{d} {d} {d} {d}\n", .{ @intFromEnum(dw.d), dw.w, seed, v, H.hasher_write_u64(seed, @intFromEnum(dw.d), v, dw.w) });
        }
        const wide = rng.int(u128);
        for ([_]H.HasherDomain{ .u128, .i128, .dec }) |d| {
            try out.print("hwwide_{d} {d} {d} {d}\n", .{ @intFromEnum(d), seed, wide, H.hasher_write_u128(seed, @intFromEnum(d), @truncate(wide), @truncate(wide >> 64)) });
        }
        const f32_edges = [_]u32{ 0, 0x8000_0000, 0x7fc0_0000, 0xffc0_0001, 0x7f80_0001, rng.int(u32) };
        for (f32_edges) |b| try out.print("hwf32 {d} {d} {d}\n", .{ seed, b, H.hasher_write_f32_bits(seed, b) });
        const f64_edges = [_]u64{ 0, 0x8000_0000_0000_0000, 0x7ff8_0000_0000_0000, 0xfff8_0000_0000_0001, 0x7ff0_0000_0000_0001, rng.int(u64) };
        for (f64_edges) |b| try out.print("hwf64 {d} {d} {d}\n", .{ seed, b, H.hasher_write_f64_bits(seed, b) });
        const len = rng.uintLessThan(usize, buf.len);
        rng.bytes(buf[0..len]);
        const h = if (len == 0) "-" else std.fmt.bufPrint(&hex_buf, "{x}", .{buf[0..len]}) catch unreachable;
        try out.print("hwstr {d} {s} {d}\n", .{ seed, h, H.hasher_write_bytes(seed, @intFromEnum(H.HasherDomain.str), &buf, len) });
        try out.print("hfinish {d} 0 {d}\n", .{ seed, H.hasher_finish(seed) });
    }
}

/// Dec transcendental vectors from builtins/dec.zig: `decconst_<name> 0 0
/// <raw>` for the constants the algorithms use, then `decm_<op> <a> <b>
/// <raw result>` or `crash:<message>` (the crash hook records the message).
fn emitDecMathVectors(out: *std.Io.Writer, rng: std.Random) std.Io.Writer.Error!void {
    try out.print("decconst_pi 0 0 {d}\n", .{RocDec.pi.num});
    try out.print("decconst_tau 0 0 {d}\n", .{RocDec.tau.num});
    try out.print("decconst_half_pi 0 0 {d}\n", .{RocDec.half_pi.num});
    try out.print("decconst_ln2 0 0 {d}\n", .{RocDec.ln2.num});
    const one = RocDec.one_point_zero_i128;
    var inputs: [64]i128 = undefined;
    const edges = [_]i128{ 0, one, -one, 2 * one, one / 2, -one / 2, RocDec.pi.num, RocDec.half_pi.num, -RocDec.half_pi.num, RocDec.tau.num, 1, -1, 3 * one, 10 * one, -10 * one, 100 * one, one + 1, -one - 1, std.math.maxInt(i128), std.math.minInt(i128) };
    for (edges, 0..) |e, i| inputs[i] = e;
    var n: usize = edges.len;
    while (n < inputs.len) : (n += 1) {
        inputs[n] = switch (rng.uintLessThan(u8, 4)) {
            0 => rng.intRangeAtMost(i128, -4 * one, 4 * one),
            1 => rng.intRangeAtMost(i128, -1000 * one, 1000 * one),
            2 => rng.intRangeAtMost(i128, -one, one),
            else => randomI128(rng),
        };
    }
    for (inputs) |a| {
        inline for (.{ "sin", "cos", "tan", "asin", "acos", "atan", "sqrt", "log" }) |name| {
            try emitDecMath1(out, name, a);
        }
        for (inputs[0..24]) |b| {
            try emitDecMath2(out, "pow", a, b);
            try emitDecMath2(out, "atan2", a, b);
        }
    }
}

fn emitDecMath1(out: *std.Io.Writer, comptime name: []const u8, a: i128) std.Io.Writer.Error!void {
    const r = decMathCall(name, a, 0);
    if (r.crash) |msg| {
        try out.print("decm_{s} {d} 0 crash:{s}\n", .{ name, a, msg });
    } else try out.print("decm_{s} {d} 0 {d}\n", .{ name, a, r.value });
}

fn emitDecMath2(out: *std.Io.Writer, comptime name: []const u8, a: i128, b: i128) std.Io.Writer.Error!void {
    const r = decMathCall(name, a, b);
    if (r.crash) |msg| {
        try out.print("decm_{s} {d} {d} crash:{s}\n", .{ name, a, b, msg });
    } else try out.print("decm_{s} {d} {d} {d}\n", .{ name, a, b, r.value });
}

/// The pipe a forked Dec math child reports through.
var dec_math_pipe: std.c.fd_t = -1;

/// RocOps crash hook for the child: report the message and exit, since a
/// builtin's crash hook must not return.
fn decMathChildCrash(_: *builtins.host_abi.RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = std.c.write(dec_math_pipe, "c", 1);
    _ = std.c.write(dec_math_pipe, bytes, len);
    std.c._exit(0);
}

const DecMathResult = struct { crash: ?[]const u8, value: i128 };
var dec_math_crash_buf: [256]u8 = undefined;

/// Run one Dec math builtin in a forked child so a crash can be recorded.
fn decMathCall(comptime name: []const u8, a: i128, b: i128) DecMathResult {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) @panic("pipe failed");
    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.close(fds[0]);
        dec_math_pipe = fds[1];
        var env = builtins.utils.TestEnv.init(std.heap.c_allocator);
        var ops = env.getOps().*;
        ops.roc_crashed = &decMathChildCrash;
        const x = RocDec{ .num = a };
        const y = RocDec{ .num = b };
        const D = builtins.dec;
        const r: i128 = if (comptime std.mem.eql(u8, name, "sin")) D.sinC(x, &ops) else if (comptime std.mem.eql(u8, name, "cos")) D.cosC(x, &ops) else if (comptime std.mem.eql(u8, name, "tan")) D.tanC(x, &ops) else if (comptime std.mem.eql(u8, name, "asin")) D.asinC(x, &ops) else if (comptime std.mem.eql(u8, name, "acos")) D.acosC(x, &ops) else if (comptime std.mem.eql(u8, name, "atan")) D.atanC(x, &ops) else if (comptime std.mem.eql(u8, name, "sqrt")) D.sqrtC(x, &ops) else if (comptime std.mem.eql(u8, name, "log")) D.logC(x, &ops) else if (comptime std.mem.eql(u8, name, "pow")) D.powC(x, y, &ops) else D.atan2C(x, y, &ops);
        _ = std.c.write(fds[1], "v", 1);
        _ = std.c.write(fds[1], std.mem.asBytes(&r), 16);
        std.c._exit(0);
    }
    _ = std.c.close(fds[1]);
    var buf: [300]u8 = undefined;
    var got: usize = 0;
    while (true) {
        const n = std.c.read(fds[0], buf[got..].ptr, buf.len - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    _ = std.c.close(fds[0]);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    if (got >= 17 and buf[0] == 'v') return .{ .crash = null, .value = std.mem.bytesToValue(i128, buf[1..17]) };
    if (got >= 1 and buf[0] == 'c') {
        @memcpy(dec_math_crash_buf[0 .. got - 1], buf[1..got]);
        return .{ .crash = dec_math_crash_buf[0 .. got - 1], .value = 0 };
    }
    @panic("dec math child produced no result");
}

/// Float transcendental vectors from builtins/float_math: `fm64_<op> <a bits>
/// <b bits> <result bits>` and `fm32_<op>` likewise (NaN results normalized,
/// as Roc does). Inputs: edge values, random bit patterns, values near
/// multiples of pi/2, small and huge magnitudes.
fn emitFloatMathVectors(out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    const M64 = builtins.float_math_f64;
    const M32 = builtins.float_math_f32;
    // The f64 rem_pio2 folds `3 * pio2_1t` at comptime precision.
    const pio2_1t = 6.07710050650619224932e-11;
    try out.print("fmconst_three_pio2_1t 0 0 {d}\n", .{@as(u64, @bitCast(@as(f64, 3 * pio2_1t)))});
    var a64: [64]f64 = undefined;
    const e64 = [_]f64{ 0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, 3.0, 0.1, 1e-300, 1e300, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), std.math.pi / 2.0, std.math.pi, 1.5707963267948966e0, 4.71238898038469, 1e6, 1e22, 1.7976931348623157e308, 5e-324, 2.2250738585072014e-308, 0.9999999999999999, 1.0000000000000002 };
    for (e64, 0..) |e, i| a64[i] = e;
    var n: usize = e64.len;
    while (n < a64.len) : (n += 1) a64[n] = randomF64(rng);
    var a32: [64]f32 = undefined;
    const e32 = [_]f32{ 0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, 3.0, 0.1, 1e-30, 1e30, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), std.math.pi / 2.0, std.math.pi, 1e6, 3.4028235e38, 1e-45, 1.1754944e-38, 0.99999994, 1.0000001 };
    for (e32, 0..) |e, i| a32[i] = e;
    n = e32.len;
    while (n < a32.len) : (n += 1) a32[n] = @floatCast(randomF64(rng));
    for (0..count / 64 + 1) |round| {
        if (round > 0) {
            for (&a64) |*v| v.* = randomF64(rng);
            for (&a32) |*v| v.* = if (rng.boolean()) @floatCast(randomF64(rng)) else @bitCast(rng.int(u32));
        }
        for (a64) |a| {
            inline for (.{ "sin", "cos", "tan", "asin", "acos", "atan" }) |name| {
                const r = @field(M64, name)(a);
                try out.print("fm64_{s} {d} 0 {d}\n", .{ name, @as(u64, @bitCast(a)), f64Bits(r) });
            }
            // F64 log is `@log`, which resolves to the C library's `log`.
            try out.print("fm64_log {d} 0 {d}\n", .{ @as(u64, @bitCast(a)), f64Bits(@log(a)) });
            for (a64[0..16]) |b| {
                try out.print("fm64_pow {d} {d} {d}\n", .{ @as(u64, @bitCast(a)), @as(u64, @bitCast(b)), f64Bits(M64.pow(a, b)) });
                try out.print("fm64_atan2 {d} {d} {d}\n", .{ @as(u64, @bitCast(a)), @as(u64, @bitCast(b)), f64Bits(M64.atan2(a, b)) });
            }
        }
        for (a32) |a| {
            inline for (.{ "sin", "cos", "tan", "asin", "acos", "atan", "log" }) |name| {
                const r = @field(M32, name)(a);
                try out.print("fm32_{s} {d} 0 {d}\n", .{ name, @as(u32, @bitCast(a)), f32Bits(r) });
            }
            for (a32[0..16]) |b| {
                try out.print("fm32_pow {d} {d} {d}\n", .{ @as(u32, @bitCast(a)), @as(u32, @bitCast(b)), f32Bits(M32.pow(a, b)) });
                try out.print("fm32_atan2 {d} {d} {d}\n", .{ @as(u32, @bitCast(a)), @as(u32, @bitCast(b)), f32Bits(M32.atan2(a, b)) });
            }
        }
    }
}

fn printHex(out: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    if (bytes.len == 0) return out.writeAll("-");
    for (bytes) |b| try out.print("{x:0>2}", .{b});
}

fn rocListSlice(l: builtins.list.RocList) []const u8 {
    if (l.bytes) |p| return p[0..l.length];
    return &.{};
}

/// SHA-256 and BLAKE3 vectors from `builtins.crypto` (the interpreter's
/// implementation): one-shot digests, and incremental chains recording every
/// serialized state, over lengths that cross the 64-byte block, 1024-byte
/// chunk and multi-chunk subtree boundaries. Lines: `c<alg>_hash <input> 0
/// <digest>`, `c<alg>_empty 0 0 <state>`, `c<alg>_write <state> <input>
/// <state>`, `c<alg>_finish <state> 0 <digest>`, all hex (`-` when empty).
fn emitCryptoVectors(out: *std.Io.Writer, gpa: std.mem.Allocator, rng: std.Random, count: usize) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const C = builtins.crypto;
    var env = builtins.utils.TestEnv.init(gpa);
    defer env.deinit();
    const ops = env.getOps();
    const lengths = [_]usize{ 0, 1, 3, 55, 56, 63, 64, 65, 127, 128, 129, 1023, 1024, 1025, 2047, 2048, 2049, 3072, 4096, 4097, 5000, 8192, 9000 };
    const buf = try gpa.alloc(u8, 9000);
    defer gpa.free(buf);
    rng.bytes(buf);
    for (lengths) |n| {
        for ([_][]const u8{ "csha", "cb3" }) |alg| {
            const d = if (alg[1] == 's') C.sha256HashBytes(buf.ptr, n, ops) else C.blake3HashBytes(buf.ptr, n, ops);
            try out.print("{s}_hash ", .{alg});
            try printHex(out, buf[0..n]);
            try out.writeAll(" 0 ");
            try printHex(out, rocListSlice(d));
            try out.writeAll("\n");
        }
    }
    for (0..count / 10 + 1) |_| {
        for ([_][]const u8{ "csha", "cb3" }) |alg| {
            const sha = alg[1] == 's';
            var state = if (sha) C.sha256HasherEmpty(ops) else C.blake3HasherEmpty(ops);
            try out.print("{s}_empty 0 0 ", .{alg});
            try printHex(out, rocListSlice(state));
            try out.writeAll("\n");
            const steps = 1 + rng.uintLessThan(usize, 6);
            for (0..steps) |_| {
                const n = if (rng.boolean()) lengths[rng.uintLessThan(usize, lengths.len)] else rng.uintLessThan(usize, 3000);
                const start = rng.uintLessThan(usize, buf.len - n + 1);
                const input = buf[start..][0..n];
                const s = rocListSlice(state);
                const next = if (sha) C.sha256HasherWrite(s.ptr, s.len, input.ptr, n, ops) else C.blake3HasherWrite(s.ptr, s.len, input.ptr, n, ops);
                try out.print("{s}_write ", .{alg});
                try printHex(out, s);
                try out.writeAll(" ");
                try printHex(out, input);
                try out.writeAll(" ");
                try printHex(out, rocListSlice(next));
                try out.writeAll("\n");
                state = next;
                const ns = rocListSlice(state);
                const d = if (sha) C.sha256HasherFinish(ns.ptr, ns.len, ops) else C.blake3HasherFinish(ns.ptr, ns.len, ops);
                try out.print("{s}_finish ", .{alg});
                try printHex(out, ns);
                try out.writeAll(" 0 ");
                try printHex(out, rocListSlice(d));
                try out.writeAll("\n");
            }
        }
    }
}

/// A vector whose 16-bit chunks are lane-boundary patterns or random bits.
fn randomVector(rng: std.Random) u128 {
    if (rng.uintLessThan(u8, 4) == 0) return rng.int(u128);
    const chunks = [_]u16{ 0, 0xffff, 0x8000, 0x7fff, 0x0080, 0x7f80, 0x8080, 0x0001 };
    var v: u128 = 0;
    for (0..8) |i| {
        const c: u16 = if (rng.boolean()) chunks[rng.uintLessThan(usize, chunks.len)] else rng.int(u16);
        v |= @as(u128, c) << @intCast(16 * i);
    }
    return v;
}

const SimdShape = enum { same, widen, narrow, fixed };
const SimdCase = struct { op: builtins.simd.Op, kinds: []const builtins.simd.Kind, shape: SimdShape = .same, ret: ?builtins.simd.Kind = null };

/// SIMD vectors over every op and every kind Roc exposes it for, from
/// `builtins.simd.eval`, the interpreter's oracle. Line format:
/// `simd_<op>_<arg kind>_<ret kind> <a hex>:<b hex> <c> <result hex>`; scalar
/// results are truncated to the Roc result width as the interpreter does.
fn emitSimdVectors(out: *std.Io.Writer, rng: std.Random, count: usize) std.Io.Writer.Error!void {
    const S = builtins.simd;
    const all = [_]S.Kind{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4, .u64x2, .i64x2 };
    const sat = [_]S.Kind{ .u8x16, .i8x16, .u16x8, .i16x8 };
    const cases = [_]SimdCase{
        .{ .op = .splat, .kinds = &all },
        .{ .op = .get_lane_unchecked, .kinds = &all },
        .{ .op = .with_lane_unchecked, .kinds = &all },
        .{ .op = .to_u128_bits, .kinds = &all },
        .{ .op = .from_u128_bits, .kinds = &all },
        .{ .op = .add_wrap, .kinds = &all },
        .{ .op = .sub_wrap, .kinds = &all },
        .{ .op = .add_sat, .kinds = &sat },
        .{ .op = .sub_sat, .kinds = &sat },
        .{ .op = .neg_wrap, .kinds = &.{ .i8x16, .i16x8, .i32x4, .i64x2 } },
        .{ .op = .abs_wrap, .kinds = &.{ .i8x16, .i16x8, .i32x4 } },
        .{ .op = .min, .kinds = &all },
        .{ .op = .max, .kinds = &all },
        .{ .op = .abs_diff, .kinds = &.{ .u8x16, .u16x8 } },
        .{ .op = .avg_rounded, .kinds = &.{ .u8x16, .u16x8 } },
        .{ .op = .mul_wrap, .kinds = &all },
        .{ .op = .mul_high, .kinds = &.{ .u16x8, .i16x8 } },
        .{ .op = .mul_q15_sat, .kinds = &.{.i16x8} },
        .{ .op = .mul_wide_lo, .kinds = &.{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4 }, .shape = .widen },
        .{ .op = .mul_wide_hi, .kinds = &.{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4 }, .shape = .widen },
        .{ .op = .dot_pairs, .kinds = &.{.i16x8}, .shape = .fixed, .ret = .i32x4 },
        .{ .op = .dot_pairs_sat, .kinds = &.{.u8x16}, .shape = .fixed, .ret = .i16x8 },
        .{ .op = .sad, .kinds = &.{.u8x16}, .shape = .fixed, .ret = .u64x2 },
        .{ .op = .@"and", .kinds = &all },
        .{ .op = .@"or", .kinds = &all },
        .{ .op = .xor, .kinds = &all },
        .{ .op = .not, .kinds = &all },
        .{ .op = .bit_select, .kinds = &all },
        .{ .op = .eq_lanes, .kinds = &all },
        .{ .op = .gt_lanes, .kinds = &all },
        .{ .op = .gte_lanes, .kinds = &all },
        .{ .op = .bitmask, .kinds = &all },
        .{ .op = .shl_wrap, .kinds = &all },
        .{ .op = .shr_wrap, .kinds = &all },
        .{ .op = .shr_zf_wrap, .kinds = &all },
        .{ .op = .shr_rounded, .kinds = &.{ .i16x8, .i32x4 } },
        .{ .op = .interleave_lo, .kinds = &all },
        .{ .op = .interleave_hi, .kinds = &all },
        .{ .op = .even_lanes, .kinds = &all },
        .{ .op = .odd_lanes, .kinds = &all },
        .{ .op = .reverse_lanes, .kinds = &all },
        .{ .op = .table_lookup, .kinds = &.{.u8x16} },
        .{ .op = .concat_shift_bytes, .kinds = &.{.u8x16} },
        .{ .op = .widen_lo, .kinds = &.{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4 }, .shape = .widen },
        .{ .op = .widen_hi, .kinds = &.{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4 }, .shape = .widen },
        .{ .op = .pairwise_add_widen, .kinds = &sat, .shape = .widen },
        .{ .op = .narrow_wrap, .kinds = &.{ .u16x8, .i16x8, .u32x4, .i32x4, .u64x2, .i64x2 }, .shape = .narrow },
        .{ .op = .narrow_sat, .kinds = &.{ .u16x8, .i16x8, .u32x4, .i32x4 }, .shape = .narrow },
        .{ .op = .sum_lanes, .kinds = &.{ .u8x16, .i8x16, .u16x8, .i16x8, .u32x4, .i32x4 } },
        .{ .op = .sum_lanes_wrap, .kinds = &.{ .u64x2, .i64x2 } },
        .{ .op = .clmul_lo, .kinds = &.{.u64x2} },
        .{ .op = .clmul_hi, .kinds = &.{.u64x2} },
    };
    for (cases) |case| for (case.kinds) |kind| {
        var rets: [2]S.Kind = undefined;
        const ret_kinds: []const S.Kind = switch (case.shape) {
            .same => blk: {
                rets[0] = kind;
                break :blk rets[0..1];
            },
            .fixed => blk: {
                rets[0] = case.ret.?;
                break :blk rets[0..1];
            },
            .widen, .narrow => blk: {
                const index = @intFromEnum(kind);
                // Kinds are ordered u, i per width: the next/previous width pair.
                const base = if (case.shape == .widen) (index | 1) + 1 else (index & ~@as(u3, 1)) - 2;
                rets[0] = @enumFromInt(base);
                rets[1] = @enumFromInt(base + 1);
                break :blk rets[0..2];
            },
        };
        for (ret_kinds) |ret| for (0..count) |_| {
            const a = randomVector(rng);
            var b = randomVector(rng);
            var c: u128 = randomVector(rng);
            const op = case.op;
            if (op == .get_lane_unchecked or op == .with_lane_unchecked) b = rng.uintLessThan(u8, kind.laneCount());
            if (op == .shl_wrap or op == .shr_wrap or op == .shr_zf_wrap or op == .shr_rounded) b = if (rng.boolean()) rng.uintLessThan(u8, kind.laneBits() + 1) else rng.int(u8);
            if (op == .concat_shift_bytes) c = rng.uintLessThan(u8, 17);
            var r = S.eval(case.op, kind, ret, a, b, c);
            const result_bits: u8 = if (op == .get_lane_unchecked)
                kind.laneBits()
            else if (op == .bitmask)
                16
            else if (op == .sum_lanes or op == .sum_lanes_wrap)
                (if (kind.laneBits() <= 16) 32 else 64)
            else
                128;
            if (result_bits < 128) r &= (@as(u128, 1) << @intCast(result_bits)) - 1;
            const c_out: u128 = if (op == .with_lane_unchecked) c & 0xffff_ffff_ffff_ffff else c;
            try out.print("simd_{s}_{s}_{s} {x:0>32}:{x:0>32} {d} {x:0>32}\n", .{ @tagName(case.op), @tagName(kind), @tagName(ret), a, b, c_out, r });
        };
    };
}

/// Random doubles across magnitudes: raw bit patterns, small ranges, values
/// near multiples of pi/2, and powers-of-two-scaled values.
fn randomF64(rng: std.Random) f64 {
    return switch (rng.uintLessThan(u8, 6)) {
        0 => @bitCast(rng.int(u64)),
        1 => (rng.float(f64) - 0.5) * 20.0,
        2 => (rng.float(f64) - 0.5) * 2.0,
        3 => @as(f64, @floatFromInt(rng.intRangeAtMost(i32, -1000, 1000))) * (std.math.pi / 2.0) + (rng.float(f64) - 0.5) * 1e-6,
        4 => std.math.ldexp(rng.float(f64) + 0.5, rng.intRangeAtMost(i32, -1074, 1023)) * (if (rng.boolean()) @as(f64, 1) else -1),
        else => (rng.float(f64) + 0.5) * @as(f64, if (rng.boolean()) 1.0 else 0.25),
    };
}

const MainError = std.Io.Writer.Error || std.fmt.ParseIntError || std.mem.Allocator.Error || CoreCtx.StdioError || error{Unexpected};

/// Entry point: `luajit-numeric-vectors [seed] [count]` writes vectors to stdout.
pub fn main(init: std.process.Init) MainError!void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const seed: u64 = if (args.len > 1) try std.fmt.parseInt(u64, args[1], 10) else 20260930;
    const count: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 2000;

    const gpa = init.arena.allocator();
    var writer: std.Io.Writer.Allocating = .init(gpa);
    const out = &writer.writer;

    for (edge_i128) |a| {
        try emitFormat(out, a);
        for (edge_i128) |b| try emitI128Pair(out, a, b);
    }
    for (edge_i128) |a| for (edge_i128) |b| try emitU128Pair(out, @bitCast(a), @bitCast(b));

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    // First, while this process is small: each Dec math case runs in a forked child.
    try emitDecMathVectors(out, rng);
    // Dec products near exact multiples of 10^18 exercise the rounding edge of
    // mul_and_decimalize's reciprocal (x + 1) * floor(2^315 / 10^18) >> 315.
    for (0..count) |_| {
        const one = RocDec.one_point_zero_i128;
        const a: i128 = rng.intRangeAtMost(i128, -1_000_000_000, 1_000_000_000) * one + rng.intRangeAtMost(i128, -1, 1);
        const b: i128 = rng.intRangeAtMost(i128, -1_000_000_000, 1_000_000_000) * one + rng.intRangeAtMost(i128, -1, 1);
        const m = RocDec.mulWithOverflow(.{ .num = a }, .{ .num = b });
        try line(out, "dec_mul", a, b, if (m.has_overflowed) null else @as(?i128, m.value.num));
    }
    for (0..count) |_| {
        const a = randomI128(rng);
        const b = randomI128(rng);
        try emitI128Pair(out, a, b);
        try emitFormat(out, a);
        try emitU128Pair(out, randomU128(rng), randomU128(rng));
        try emitDecDivPair(out, a, b);
    }
    for (edge_i128) |a| for (edge_i128) |b| try emitDecDivPair(out, a, b);
    inline for (.{ i8, u8, i16, u16, i32, u32, i64, u64, i128, u128 }) |T| try emitIntDivFamily(T, out, rng, count);
    inline for (.{ i8, u8, i16, u16, i32, u32, i64, u64, i128, u128 }) |T| try emitConversions(T, out, rng);
    inline for (.{ i8, u8, i16, u16, i32, u32, i64, u64, i128, u128 }) |T| try emitBitOps(T, out, rng);
    try emitFloatFormats(out, rng, count);
    try emitFloatConversions(out, rng, count);
    for (edge_i128) |d| try emitDecToInt(out, d);
    for (0..count) |_| try emitDecToInt(out, randomI128(rng));
    try emitSortVectors(out, gpa);
    try emitParseVectors(out, rng, count);
    try emitUtf8Vectors(out, gpa, rng, count);
    try emitHashVectors(out, rng, count);
    try emitFloatMathVectors(out, rng, count);
    try emitSimdVectors(out, rng, count);
    try emitCryptoVectors(out, gpa, rng, count);
    try CoreCtx.default(gpa, gpa, init.io).writeStdout(writer.written());
}
