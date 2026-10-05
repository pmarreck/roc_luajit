# Downstream compiler and backend contracts

Roc's compiler is the pinned `roc` dependency in `build.zig.zon`. Its upstream
[compiler design](https://github.com/roc-lang/roc/blob/main/design.md)
is authoritative for checked modules, post-check lowering, LIR, ARC, and LirImage.
This repository owns the driver, Lua emitter, Lua runtime, hosts, and backend tests.

The driver resolves and checks sources with Roc's `BuildEnv`. It configures
runtime lowering before checking and consumes the resulting program session's
completed compile-time facts. Platform entrypoints come from checked root
requests; names and layouts come from the lowered program. Static data is built
by Roc's static-data library from the checked artifacts and lowered program.
No downstream stage guesses or reconstructs missing compiler metadata.

The Lua emitter consumes ARC-complete LIR and committed layouts. It follows the
explicit `incref`, `decref`, `decref_if_initialized`, and `free` statements; it
never performs ownership or reference-count analysis. Unsupported instructions
produce a named refusal, never approximated output. See `ARCHITECTURE.md` for
the emitter and runtime design, including the supported instruction subset.

Headerless-app staging uses the parser-based utility from the same pinned Roc
package. Platform hosts are selected by their own `host.lua` or an exact source
fingerprint in the bundled host registry. No platform ABI is inferred.

Updating Roc means choosing one commit and running `zig fetch --save=roc` with
that commit, then validating the downstream tests. Do not copy compiler sources
or override upstream modules to make a dependency update pass.

Roc branch-probability hints preserve the Bool operand in Lua. List allocation
operations retain their exact capacity-growth semantics and consume the explicit
LIR uniqueness mask. Float logarithms follow Zig 0.16's compiler-rt algorithm
rather than depending on host libm rounding.

The differential harness selects the backend's supported `.lss` configuration
and interpreter-supported corpus cases. It lowers once for 64-bit execution,
honors explicit serial scheduling, and preserves global worker indices when
partitioning the case list. Compiler stack-budget proofs remain upstream.
