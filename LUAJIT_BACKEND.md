# Experimental Roc LuaJIT backend

This checkout is a fork of [roc-lang/roc](https://github.com/roc-lang/roc), based on `64ee0aeddc8cc0db94b446b4e4aee7e7f7c01090`. Local directory: `roc_luajit`; fork remote: [pmarreck/roc](https://github.com/pmarreck/roc). Upstream's README, AGENTS.md, design and test suite remain intact.

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
./test-all --luajit-only     # LuaJIT suite (luajit_backend/tests/run)
./test-all                   # plus upstream MiniCI
```

The suite replays upstream builtin vectors (`numeric_vectors.lua`), runs the differential runner over upstream's 2,291-case LIR eval corpus with the LIR interpreter as oracle (all agree), and runs `echo_conformance`, which builds every `test/echo` app natively and for LuaJIT and compares stdout, stderr and exit status. Unsupported constructs are counted against ratchets (`unsupported_ratchet`, `echo_unsupported_ratchet`).

On hosts with more than 32 CPUs Zig 0.16.0 segfaults while compiling `roc`, so `./build` and `./test-all` cap Zig's CPU affinity at 32 (ARCHITECTURE.md §8).
