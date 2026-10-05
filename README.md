# roc_luajit

A standalone Roc-to-LuaJIT compiler. This repository owns the Lua emitter,
runtime, platform hosts, CLI driver, and backend tests. Roc's compiler libraries
are fetched as one pinned Zig dependency; there is no compiler fork to maintain.

Requires Zig 0.16.0 and LuaJIT 2.1. The optional Nix shell provides both:

```sh
nix develop
zig build roc
zig-out/bin/roc build hello.roc --output=hello.lua
luajit hello.lua
```

The default backend is LuaJIT. `--target=luajit` remains accepted for existing
scripts. `roc check app.roc` checks without emitting Lua. Headerless `main!`
programs use the default Echo platform; explicit platforms provide `host.lua`
or match an exact fingerprint in the bundled host registry.

The driver calls Roc's dependency resolution, checking, compile-time
finalization, LIR lowering, and static-data libraries. The emitter receives
ARC-complete LIR and follows its reference-count statements directly. The
implemented backend targets specialized (`.lss`) LIR; boxy instructions produce
named unsupported reports.

```sh
zig build test                         # emitter and host tests
zig build build-test-luajit-differential
zig-out/bin/luajit-differential-runner max-cases=20
zig build native                       # optional pinned upstream native oracle
./test-luajit --portable               # runtime, CLI, and differential tests
./test-luajit                          # full backend suite (Linux host tests)
```

`roc-native` is installed separately from this CLI. Its optional build fetches
a complete upstream checkout at the same SHA read from `build.zig.zon` (the
compiler-library package omits CLI test/runtime assets). Native comparisons use it;
the differential runner compares 64-bit LSS LIR with Roc's interpreter and
honors the upstream corpus's serial scheduling metadata. The eval
corpus and harness are imported from the pinned package, rather than copied.
Backend fixtures under `test/` supply the retained platform and SIMD test assets.

To update the compiler:

```sh
zig fetch --save=roc 'git+https://github.com/roc-lang/roc.git#<full-commit-sha>'
zig build roc test build-test-luajit-differential
```

Zig updates the URL and content hash together. The initial dependency baseline
comes from [upstream draft PR #12071](https://github.com/roc-lang/roc/pull/12071).
Read [design.md](design.md) for compiler boundaries and
[luajit_backend/README.md](luajit_backend/README.md) for demos and host limitations.

The retained basic-cli 0.23.0/WASI comparison currently fails upstream checking
on redundant type imports. A compatible basic-cli release is needed for that
Linux conformance lane; the failure remains visible in the full suite.
