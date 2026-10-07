# TODO

Open backend work, triaged from the fork-era log (`docs/history/PLAN.md`, which
keeps the dated detail and measurements behind each item).

## Performance

- dict_ops: the outer fold loop runs interpreted after repeated "inner loop in
  root trace" aborts blacklist it. Find an emission shape LuaJIT traces through.
  JIT parameters and a backward-goto probe loop were ruled out. Measure with
  medians of at least 15 runs.
- Leaf RC helpers: incref/decref straight from leaves instead of materializing
  an element table first (seen as `R.d64(R.m..(...))` in hot code).
- Pass sublist's `{ len, start }` record as two values (one table per call today).
- list_ops GC: per-append headers and boxed U64 elements.
- fib: call overhead and `DEPTH` bookkeeping.
- dec_math: `wide.lua` fixed 8-limb unrolled ops, or uint64 halves in hot
  functions. 26-bit-limb Knuth D was measured slower and rejected.
- str_build: find why LuaJIT's allocation sinking switches mid-run (option D).
  Candidate LuaJIT report: buffer length read after put/putf, stored into a sunk
  table, restored stale (needs a standalone repro).
- `./bm`: optional informational GC-tuned column (e.g. `setpause 800`), never gated.
- Rerun the cross-language comparison (`luajit_backend/bench/compare/run`) since
  flat list storage landed. Then compare wasm32 builds (wasmtime/wazero) with
  sizes baked in, checking that time scales with N.

## Correctness and coverage

- LuaJIT "control structure too long" in very large procedures: split into
  tail-called segment functions. No witness yet; a 2000-arm `match` builds.
- F32/F64 bit-exactness on aarch64 (FMA is off by default; NaN sign/payload
  differs by arch upstream).
- `Str.to_utf8`/`from_utf8` heap capacity sharing, if a test ever observes it.
- Open review risks, each needing a witness before any change: phantom join edge
  in the segment graph, `str_join_with` with a view separator, `assignSlots`
  dense parameter indices if LIR repeats a parameter, `M.ll_replace` tail call.
  New runtime helpers must call `str()` before `#`/`==` on a possible view.

## Platforms and demos

- basic-cli host on macOS: `statx` and Linux `dirent` layouts.
- basic-cli 0.23.0 fails checking under the pinned compiler (redundant type
  imports); needs a compatible release for the native/WASI lanes.
- Vendor the 9 URL-package Exercism exercises (roc-parser etc.) with licences so
  they run offline.
- Lua platform: native hosts for arm64 musl and macOS; File bytes and
  directories; Lua calling back into Roc; measure host-call encode/decode cost.
- WASI basic-cli: maybe SQLite compiled to wasm. Processes, sockets and tty raw
  mode are out of reach on preview1.
