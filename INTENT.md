# Roc LuaJIT backend

The owner requested this experiment on September 30, 2026. The owner-supplied design is [SPEC.md](SPEC.md), copied unchanged from the owner's notes. This checkout forks Roc at `64ee0aeddc8cc0db94b446b4e4aee7e7f7c01090`; preserve upstream's `main` branch convention and compiler invariants.

## Purpose and scope

Add an experimental backend that transpiles Roc's LIR into Lua 5.1-compatible source executed by stock LuaJIT 2.1. Reuse the existing frontend, checking, lowering and test suite. The intended uses are running typed functional Roc logic in LuaJIT applications and eventually reaching Lua/native libraries through controlled platform boundaries.

Observable Roc value semantics, numeric exactness and explicit compiler metadata govern representation choices. Do not write a separate source parser, silently invent missing semantics, clone every function argument, emit LuaJIT bytecode or rewrite unrelated compiler stages. Unsupported constructs must be reported explicitly, not dynamically reinterpreted.

## First milestone and acceptance

M0 is a code-cited ARCHITECTURE.md at the pinned revision: LIR producer/consumer boundaries, layouts, ARC insertion, uniqueness/storage reuse, platform ABI and reusable oracle tests. Investigate the tension between upstream's explicit ARC contract and SPEC.md's GC-backed representation proposals before choosing how to map those operations. Do not silently skip ARC or reconstruct ownership in the backend.

After the architecture is established, proceed feature-by-feature using differential TDD. Existing Roc tests/reference execution are the oracle; compare observable output, status and relevant effects with generated LuaJIT execution. First demonstrate scalars/functions/conditionals and a minimal stdout platform. Exact numeric boundaries and alias-preserving updates remain mandatory, even when deferred to later milestones.

Use Nix flakes for toolchains, runtime dependencies, package builds and checks. Retain the upstream native oracle alongside the experimental backend; its successful build does not prove LuaJIT code generation works. Keep compiler dependency fetching outside ordinary sandboxed builds. Native-platform and cross-compilation evidence must be distinguished.

No upstream PR, customer release or broad compiler redesign is authorized by this setup. Report architectural blockers rather than weakening this intent.
