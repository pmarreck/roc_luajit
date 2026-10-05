# Roc on wasm32 (WASI basic-cli) against native and LuaJIT

2026-10-04 13:50 EDT, x86_64-linux-threadripper (AMD Ryzen Threadripper 3990X 64-Core Processor), commit 72b4d5c941, 10 runs each, K = scale x 1, load average 15.16 18.72 27.34.
Runtimes: wasmtime 48.0.0, wazero 1.12.0, LuaJIT 2.1.1785763465.

Each cell is the ratio to the native headerless build (lower is better): total time at K arguments / time per K of work with startup cancelled. Native's own times are in ms; wasm KB is the module size.

| benchmark | K | native ms | native basic-cli | Roc LuaJIT | wasmtime | wazero | wasm KB |
|---|---|---|---|---|---|---|---|
| startup | 1 | 0.7 | 1.1x | 8.8x | 21.8x | 53.6x | 19 |
| fib | 8 | 8.5 | 1.0x / 1.0x | 4.8x / 4.5x | 3.4x / 1.5x | 6.2x / 2.2x | 19 |
| dec_math | 2 | 13.0 | 0.9x / 0.9x | 4.0x / 3.4x | 2.5x / 1.4x | 5.0x / 1.7x | 25 |
| dict_ops | 2 | 3.3 | 1.2x / 1.0x | 18.1x / 12.6x | 6.2x / 2.4x | 24.5x / 5.8x | 35 |
| list_ops | 2 | 2.6 | 1.8x / 1.9x | 7.9x / 5.9x | 7.4x / 2.3x | 25.4x / 12.4x | 22 |
| str_build | 2 | 5.0 | 1.0x / 1.1x | 3.8x / 3.0x | 4.1x / 1.6x | 14.5x / 5.3x | 20 |

startup has no work term (it does none). A work ratio near 0 or negative means the run is too short for the noise; read the total instead. wasmtime and wazero compile the module on every run unless their caches hold it, so total includes compilation.
