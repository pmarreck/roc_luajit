//! Structural assertions for backend stage boundaries.

const std = @import("std");

fn expectContains(haystack: []const u8, needle: []const u8) error{TestUnexpectedResult}!void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) error{TestUnexpectedResult}!void {
    try std.testing.expect(std.mem.find(u8, haystack, needle) == null);
}

test "backends consume explicit LIR reference-count statements without ARC analysis" {
    const dev_lir_codegen = @embedFile("dev/LirCodeGen.zig");
    const llvm_codegen = @embedFile("llvm/MonoLlvmCodeGen.zig");
    const wasm_codegen = @embedFile("wasm/WasmCodeGen.zig");
    const lua_emitter = @embedFile("lua/LuaEmitter.zig");

    inline for (.{ dev_lir_codegen, llvm_codegen, wasm_codegen, lua_emitter }) |backend_source| {
        try expectContains(backend_source, ".incref =>");
        try expectContains(backend_source, ".decref =>");
        try expectContains(backend_source, ".decref_if_initialized =>");

        try expectNotContains(backend_source, "arc_solve");
        try expectNotContains(backend_source, "arc_certify");
        try expectNotContains(backend_source, "ArcSolve");
        try expectNotContains(backend_source, "ArcCertify");
        try expectNotContains(backend_source, "computePinnedProcs");
        try expectNotContains(backend_source, "computeVisibility");
        try expectNotContains(backend_source, "computeUniqueness");
        try expectNotContains(backend_source, "borrow inference");
        try expectNotContains(backend_source, "borrow certifier");
        try expectNotContains(backend_source, "ownership signature");
        try expectNotContains(backend_source, "ownership signatures");
        try expectNotContains(backend_source, "refcount analysis");
        try expectNotContains(backend_source, "reference-count analysis");
    }
}

test "the Lua emitter is independent of the LIR interpreter it is compared against" {
    // The LuaJIT differential runner uses the LIR interpreter as its oracle.
    // An emitter that reached the interpreter could pass by running the
    // oracle twice, so the emitter source must not name it.
    const lua_emitter = @embedFile("lua/LuaEmitter.zig");
    try expectNotContains(lua_emitter, "@import(\"eval\")");
    try expectNotContains(lua_emitter, "LirInterpreter");
    try expectNotContains(lua_emitter, "interpreter.zig");
}
