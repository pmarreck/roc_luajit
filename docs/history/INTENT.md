# Roc LuaJIT backend

BDFN (Benevolent Dictator For Now) requested this experiment on September 30, 2026. The BDFN-supplied design is [SPEC.md](SPEC.md), copied unchanged from BDFN's notes. The original experiment forked Roc. This repository now imports Roc's compiler libraries through the single pinned dependency in `build.zig.zon`; preserve the upstream compiler invariants.

## Purpose and scope

Add an experimental backend that transpiles Roc's LIR into Lua 5.1-compatible source executed by stock LuaJIT 2.1. Reuse the existing frontend, checking, lowering and test suite. The intended uses are running typed functional Roc logic in LuaJIT applications and eventually reaching Lua/native libraries through controlled platform boundaries.

Observable Roc value semantics, numeric exactness and explicit compiler metadata govern representation choices. Do not write a separate source parser, silently invent missing semantics, clone every function argument, emit LuaJIT bytecode or rewrite unrelated compiler stages. Unsupported constructs must be reported explicitly, not dynamically reinterpreted.

## First milestone and acceptance

M0 is a code-cited ARCHITECTURE.md at the pinned revision: LIR producer/consumer boundaries, layouts, ARC insertion, uniqueness/storage reuse, platform ABI and reusable oracle tests. Investigate the tension between upstream's explicit ARC contract and SPEC.md's GC-backed representation proposals before choosing how to map those operations. Do not silently skip ARC or reconstruct ownership in the backend.

After the architecture is established, proceed feature-by-feature using differential TDD. Existing Roc tests/reference execution are the oracle; compare observable output, status and relevant effects with generated LuaJIT execution. First demonstrate scalars/functions/conditionals and a minimal stdout platform. Exact numeric boundaries and alias-preserving updates remain mandatory, even when deferred to later milestones.

Use Nix flakes for toolchains, runtime dependencies, package builds and checks. Retain the upstream native oracle alongside the experimental backend; its successful build does not prove LuaJIT code generation works. Keep compiler dependency fetching outside ordinary sandboxed builds. Native-platform and cross-compilation evidence must be distinguished.

No upstream PR, customer release or broad compiler redesign is authorized by this setup. Report architectural blockers rather than weakening this intent.
