# Roc (native, LuaJIT) against other runtimes

2026-10-02 12:38 EDT, x86_64-linux-threadripper, x86_64, commit 503c843126, 10 runs each, K = scale x 8, load average 10.29 28.07 21.39.
Runtimes: LuaJIT 2.1.1785763465, CPython 3.14.7, PyPy 7.3.20, Ruby 3.4.9 with YJIT, Elixir 1.18.4 on OTP 28.

Each cell is the ratio to native Roc (lower is better): total time at K arguments / time per K of work with startup cancelled. Native's own times are in ms.

| benchmark | K | native ms | Roc LuaJIT | PyPy | Ruby YJIT | Elixir | CPython |
|---|---|---|---|---|---|---|---|
| startup | 1 | 0.6 | 9.7x | 133.2x | 79.5x | 817.9x | 28.1x |
| fib | 64 | 59.8 | 4.5x / 4.5x | 3.8x / 2.0x | 3.9x / 3.1x | 11.4x / 2.1x | 28.1x / 28.6x |
| dec_math | 16 | 101.8 | 3.5x / 3.4x | 1.1x / 0.2x | 2.9x / 2.4x | 5.9x / 0.4x | 1.6x / 1.4x |
| dict_ops | 16 | 21.0 | 11.1x / 12.1x | 4.5x / 0.5x | 3.1x / 0.8x | 28.7x / 3.9x | 2.6x / 1.7x |
| list_ops | 16 | 16.6 | 6.1x / 5.4x | 6.9x / 1.9x | 9.6x / 6.3x | 43.1x / 10.5x | 8.5x / 7.2x |
| str_build | 16 | 34.1 | 4.9x / 5.7x | 4.3x / 1.9x | 5.4x / 3.1x | 16.9x / 1.7x | 5.4x / 3.9x |

startup has no work term (it does none). A work ratio near 0 or negative means the run is too short for the noise; read the total instead.
