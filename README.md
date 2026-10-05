# roc_luajit

A standalone Roc-to-LuaJIT compiler. It transpiles Roc's ARC-complete LIR into
one self-contained LuaJIT 2.1 source file. This repository owns the Lua emitter,
runtime, platform hosts, CLI driver, and backend tests. Roc's compiler libraries
are fetched as one pinned Zig dependency; there is no compiler fork to maintain.
Unsupported constructs are reported as named refusals, never approximated.

Requires Zig 0.16.0 and LuaJIT 2.1. The optional Nix shell provides both:

```sh
nix develop
./build                                  # zig-out/bin/roc (ReleaseFast; --debug for Debug)
zig-out/bin/roc build hello.roc --output=hello.lua
luajit hello.lua
```

The default backend is LuaJIT. `--target=luajit` remains accepted for existing
scripts. `roc check app.roc` checks without emitting Lua. The output contains
the runtime (`src/backend/lua/*.lua`), the app's procedures (`LuaEmitter.zig`),
and the platform's LuaJIT host (`LuaHost.zig`). Headerless `main!` programs use
the default Echo platform; explicit platforms provide `host.lua` beside their
main module or match an exact fingerprint in the bundled host registry
(`src/backend/lua/hosts/`).

The driver calls Roc's dependency resolution, checking, compile-time
finalization, LIR lowering, and static-data libraries. The emitter receives
ARC-complete LIR and follows its reference-count statements directly. The
implemented backend targets specialized (`.lss`) LIR; boxy instructions produce
named unsupported reports.

## Testing

```sh
./test-all --portable                  # runtime, CLI, and differential tests
./test-all                             # full backend suite (Linux host tests)
zig build test                         # emitter and host tests
zig build build-test-luajit-differential
zig-out/bin/luajit-differential-runner max-cases=20
zig build native                       # optional pinned upstream native oracle
./bm                                   # fixed-workload timings vs. approved history
./cg; ./mg                             # CPU-growth and memory gates
luajit_backend/bench/compare/run       # LuaJIT Roc vs native Roc and other runtimes
```

`./test-luajit` is an alias for `./test-all`. Build wrappers limit concurrent
build jobs to two. Compiler tests run in the upstream repository; this package
tests its driver and backend. The suite replays upstream builtin vectors, runs
the differential runner over the pinned upstream LIR eval corpus with the LIR
interpreter as oracle, and compares native and LuaJIT builds of the echo, fx,
basic-cli, demo and Exercism apps. Unsupported constructs are counted against
ratchets. See [design.md](design.md#test-oracles). `./bm`, `./cg` and `./mg`
run the external `performance-profile` engine with the cases in
`profiling.json` and keep history at `$PERFORMANCE_HISTORY_URL`.

`roc-native` is installed separately from this CLI. Its optional build fetches
a complete upstream checkout at the same SHA read from `build.zig.zon` (the
compiler-library package omits CLI test/runtime assets). Native comparisons use it;
the differential runner compares 64-bit LSS LIR with Roc's interpreter and
honors the upstream corpus's serial scheduling metadata. The eval
corpus and harness are imported from the pinned package, rather than copied.
Backend fixtures under `test/` supply the retained platform and SIMD test assets.

## Updating the compiler

```sh
zig fetch --save=roc 'git+https://github.com/roc-lang/roc.git#<full-commit-sha>'
zig build roc test build-test-luajit-differential
```

Zig updates the URL and content hash together. The initial dependency baseline
comes from [upstream draft PR #12071](https://github.com/roc-lang/roc/pull/12071).

The retained basic-cli 0.23.0/WASI comparison currently fails upstream checking
on redundant type imports. A compatible basic-cli release is needed for that
Linux conformance lane; the failure remains visible in the full suite.

## Docs

- [design.md](design.md): compiler boundaries, backend contracts, representations, hosts, oracles.
- [TODO.md](TODO.md): open backend work.
- [luajit_backend/README.md](luajit_backend/README.md): quickstart, demos and host limitations.
- [docs/SPEC.md](docs/SPEC.md): the original owner-supplied specification, verbatim
  (SHA-256 `591d1421c70265dc93d9e6aa39df014d6ae7df92b71b32d37fbc5de799712844`).
- [docs/history/](docs/history/): the fork-era brief, M0 architecture report, decision log and progress log.
