#!/usr/bin/env bash
set -eu
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$root"
[[ "$(./build --dry-run)" == *'zig build roc -Doptimize=ReleaseFast'* ]]
[[ "$(./build --debug --dry-run)" == *'zig build roc -Doptimize=Debug'* ]]
[[ "$(./build --test --dry-run)" == *'roc test build-test-luajit-differential native'* ]]
[[ "$(./build --dry-run -- -Doptimize=ReleaseSafe)" == *'-Doptimize=ReleaseSafe'* ]]
[[ "$(./test-all --dry-run)" == *'luajit_backend/tests/run'* ]]
[[ "$(./test-all --portable --dry-run)" == *'luajit_backend/tests/portable'* ]]
if ./build --bogus >/dev/null 2>&1; then exit 1; fi
if ./test-all --bogus >/dev/null 2>&1; then exit 1; fi
echo 'wrappers: all passed'
