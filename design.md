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
produce a named refusal, never approximated output. The sections below describe
the emitter and runtime design.

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

Rationale, measurements and rejected alternatives for the decisions below are
in the decision log, `docs/history/ARCHITECTURE.md` §10, cited here by entry
title. Its `path:line` citations refer to upstream `64ee0aeddc`, not to the
pinned dependency.

## Scope and rules

- Input is ARC-complete `.lss` LIR from Roc's own lowering. There is no separate
  source parser, and no stage before the emitter is rewritten.
- Output is source text, not LuaJIT bytecode (startup is about 5 ms; bytecode
  would tie the output to one LuaJIT build and need LuaJIT at build time).
- Observable Roc semantics govern representation: exact numerics, alias-safe
  updates, and Roc's own crash messages and exit statuses for Roc-level errors
  such as division by zero or overflow.
- Every backend change is checked against an oracle (see Test oracles). Speed
  work follows measurement. Where a representation is shaped for LuaJIT's JIT at
  the cost of a simpler data model, this document says so.

## Output dialect and code shape

The output is LuaJIT 2.1 source: Lua 5.1 plus LuaJIT's documented extensions
(`goto`, `ffi`, `bit`, `LL`/`ULL` literals). One Lua function is emitted per
`LirProcSpecId`.

- `join`/`jump` become labels and gotos. Segments are laid out in reverse
  postorder, and loops are emitted as `while` headers, because LuaJIT never
  hot-counts a backward `goto`.
- Locals are coalesced by liveness (`assignSlots`). A frame that still exceeds
  LuaJIT's local limit spills to a frame table, keyed only on the explicit
  `frame_locals` count.
- The runtime avoids tail calls in hot helpers, because LuaJIT counts them
  against the trace's unroll limit (`tail_calls.lua` lint).
- Deep recursion hops to a fresh coroutine near LuaJIT's 65,500-slot stack
  (64-hop cap). Runaway recursion still reports Roc's stack overflow.
- LuaJIT builds always lower with the dev configuration, whatever `--opt` says.
- Prelude modules that most programs never use are compiled on first call.

## Reference counting (policy C)

The emitter executes every `incref`, `decref`, `decref_if_initialized` and
`free` literally. Refcounted values (Str buffers, list allocations, boxes,
erased callables) carry a count. `decref` to zero runs the helper plan's child
releases, and LuaJIT's GC reclaims the storage. Runtime uniqueness checks read
the count, and `unique_args`/`reuse_unique` masks skip the check exactly as on
other backends. Static data is never unique. Treating RC as no-ops would be
unsound (policy A) or would make accumulation loops quadratic (policy B); see
`docs/history/ARCHITECTURE.md` §4.

## Value representations

| Roc | Lua |
|---|---|
| Bool | `true`/`false` |
| U8..I32 | Lua number with explicit range checks per op family |
| U64, I64 | Lua number when -2^53 < v < 2^53, else `int64_t`/`uint64_t` cdata; either form may arrive, and results are numbers whenever they fit ("Mixed I64/U64") |
| U128, I128, Dec | immutable table of eight 16-bit limbs, least significant first (`wide.lua`, `int128.lua`), ported from `builtins/dec.zig` |
| F64 | Lua number; NaNs canonicalized on entry |
| F32 | Lua number rounded through a `float` store after every op |
| Str | a Lua string; a view `{ b = string.buffer, n }` of an append-only buffer; an integer-valued number (from integer `to_str`, formatted with `%d` on read); or a leaf for int64/uint64 cdata. Only `str_concat`, `str_count_utf8_bytes` and `str_is_eq` are view-aware. Every other op receives `rt.str(...)` operands. |
| List | header array `{alloc, offset, length, capacity, slice}`; allocation keeps rc in slot 0. A faithful port of `builtins/list.zig` (capacity growth, slices, uniqueness) |
| List of k >= 2-leaf elements | **flat storage**: element p occupies allocation slots (p-1)*k+1 .. (p-1)*k+k. A JIT-driven distortion: hosts, static lists and whole-element consumers convert with generated materializers/unpackers (`R.h`/`R.g`, `R.m`/`R.u`) |
| Records, tags (<= 16 leaves) | flattened into Lua locals by leaf shape (`shapeOf`); passed and returned as multiple values, except at the differential root, entrypoints, hosted procs and erased callables, which use tables |
| Box, erased callable | tables with a separate rc field |
| SIMD | immutable FFI `roc_v128` union, lane loops ported from `builtins/simd.zig` |
| Static data | decoded at emit time from frozen exports and built once at load as `SD[id]` |

Builtins with observable algorithms are ported, not reimplemented: float
transcendentals (`fmath.lua`, from `float_math`), Ryu-equivalent float
formatting, number parsing (`numparse.lua`), fluxsort (`sort.lua`), wyhash with
a fixed pseudo seed, SHA-256/BLAKE3 (`crypto.lua`).

## Platforms and hosts

- **Default (Echo)**: built-in host for headerless apps (`hosts/default.lua`).
- **Bundled hosts**: a platform without `host.lua` beside its `main.roc` is
  matched by SHA-256 of its sorted `.roc` sources. basic-cli 0.23.0
  (`hosts/basic_cli_0_23_0.lua`) ports the Rust host over the FFI, including
  processes, TCP, HTTP (libcurl) and SQLite (libsqlite3). Libraries are named by
  `ROC_LUAJIT_LIBCURL`/`ROC_LUAJIT_LIBSQLITE3`, else system copies are used.
  Unknown platforms are an error that prints the hash.
- **fx test platform**: `test/fx/platform/host.lua` ports upstream's `host.zig`.
- **Lua platform** (`luajit_backend/platforms/lua`): runs Lua from Roc. It has
  one hosted function, `Host.call!(op, request)`, carrying LuaValue bytes. The
  codec is written once in Roc and once in `host.lua`, and both hosts (a native
  Zig host embedding static LuaJIT, and the LuaJIT host) run `host.lua` for
  every effect. Native host: Linux x86_64 musl only.
- **WASI basic-cli** (`luajit_backend/platforms/wasi_basic_cli`): a wasm32 host
  for basic-cli apps under wasmtime, used through `roc build --replace-dep`.
  Hosted functions WASI preview1 cannot provide are generated stubs that crash
  with a named message.

## Test oracles

- **Differential runner** (`luajit-differential-runner`): each eval-corpus case
  is lowered once. The LIR interpreter is the oracle, cross-checked against the
  corpus's expected string. Verdicts are pass, diverged, lua_error,
  unsupported(reason), oracle_error, compile_skip and child_failed. The run fails
  on any divergence or error, on zero passes, or when unsupported exceeds the
  ratchet (`luajit_backend/tests/unsupported_ratchet`). Negative controls mutate
  integer and Dec literals and must diverge.
- **Conformance suites** build each app natively (`--opt=dev`) and for LuaJIT
  and compare stdout, stderr and exit status: `echo_conformance` (`test/echo`,
  demos), `fx_conformance`, `basic_cli_conformance` (also `candidate=wasm`),
  `exercism_conformance`, `lua_platform_conformance`, and `demo_expect`
  (upstream's expect scripts). Each has its own unsupported ratchet.
- **Vectors**: `numeric_vectors_parallel` replays upstream-generated builtin
  vectors (integers, Dec, floats, parsing, hashing, SIMD, crypto), with runtime
  mutants that must fail them.
- **Shape checks**: `emitted_layout` asserts emitted-code properties (no element
  tables in flat list ops, no allocation in flattened loops). `alloc_budget`
  bounds bytes per operation.
