# Experimental Roc LuaJIT backend

This repository is a standalone downstream Zig package. Roc's compiler comes from the pinned `roc` dependency in `build.zig.zon`; only the Lua backend, driver, hosts, and backend tests live here. See [README.md](README.md) for the build and dependency-update workflow.

[INTENT.md](INTENT.md) states the accepted scope; [SPEC.md](SPEC.md) is the exact owner-supplied specification (SHA-256 `591d1421c70265dc93d9e6aa39df014d6ae7df92b71b32d37fbc5de799712844`). [ARCHITECTURE.md](ARCHITECTURE.md) holds the compiler findings and the decision log (§10); [PLAN.md](PLAN.md) the work list.

## Using it

```sh
./build                                            # roc (ReleaseFast; --debug for Debug)
zig-out/bin/roc build --target=luajit test/echo/hello.roc --output=hello.lua
luajit hello.lua                                   # Hello, World!
```

The output is one self-contained LuaJIT 2.1 program: the runtime (`src/backend/lua/*.lua`), the app's procedures emitted from ARC-complete LIR (`LuaEmitter.zig`) and the platform's LuaJIT host (`LuaHost.zig`). Headerless apps use the built-in default-platform host; another platform needs a `host.lua` beside its main module.

## Testing

```sh
./test-all --portable        # runtime, CLI, and differential tests
./test-all                   # full suite, including Linux native hosts
```

The suite replays upstream builtin vectors (`numeric_vectors.lua`), runs the differential runner over the pinned upstream LIR eval corpus with the LIR interpreter as oracle, and runs `echo_conformance`, which builds every `test/echo` app natively and for LuaJIT and compares stdout, stderr and exit status. Unsupported constructs are counted against ratchets (`unsupported_ratchet`, `echo_unsupported_ratchet`).

Build wrappers limit concurrent build jobs to two. Compiler tests run in the upstream repository; this package tests its driver and backend.
