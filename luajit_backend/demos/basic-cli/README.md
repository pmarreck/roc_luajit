# basic-cli 0.23.0 conformance corpus

Vendored from [roc-lang/basic-cli](https://github.com/roc-lang/basic-cli) at commit 2f835a2, the 0.23.0 release. Licensed under UPL-1.0 (see `LICENSE`).

## What is vendored

| Path | Contents |
|---|---|
| `examples/` | The examples, including the SQLite fixture databases. |
| `tests/` | The resource-lifetime apps and the binary-reader fixtures. |
| `scripts/test_spec.json` | The run cases for each app: arguments, stdin, environment and expected output. |

## Changes

Every app's `platform "..."` line points at the 0.23.0 release URL. Upstream uses the 0.23.0-rc1 URL or a relative `../platform/main.roc`.

The tests build offline. They pass `--replace-dep <that URL> $ROC_LUAJIT_BASIC_CLI_0_23_0/main.roc`, which points at the release package that the project flake fetches by hash. They do the same for the platform's http package.

One comment in `examples/tcp-client.roc` now reads `# No more input; exit cleanly.`. Upstream joins the two clauses with a spaced em dash, which this repository's tidy check rejects.

## How it is used

`luajit_backend/tests/basic_cli_conformance` runs every Linux case of `test_spec.json`. Each case is built twice, natively and with `--target=luajit`. The runner then compares the two runs' stdout, stderr and exit status, and checks upstream's own assertions against the LuaJIT run. The LuaJIT build uses the basic-cli host bundled in `src/backend/lua/hosts/`.
