#!/usr/bin/env bash
# CLI tests for ./build and ./test-all: the Zig CPU-affinity cap and the
# commands each wrapper runs. Uses --dry-run so nothing is compiled.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$HOME/dotfiles/bin/src/capture.bash"

failures=0
out="" err="" rc=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

expect_rc() { # name expected_rc
	if [ "$rc" -eq "$2" ]; then pass "$1 (rc=$rc)"; else fail "$1: rc=$rc, expected $2; stderr: $err"; fi
}
expect_out_has() { # name needle
	case "$out" in *"$2"*) pass "$1" ;; *) fail "$1: stdout lacks '$2': $out" ;; esac
}
expect_err_has() { # name needle
	case "$err" in *"$2"*) pass "$1" ;; *) fail "$1: stderr lacks '$2': $err" ;; esac
}

cd "$ROOT" || exit 1

capture env ROC_LUAJIT_HOST_CPUS=128 ./build --dry-run
expect_rc "build dry run succeeds" 0
expect_out_has "build caps Zig at 32 cores by default" "taskset -c 0-31"
expect_out_has "build defaults to ReleaseFast" "zig build roc -Doptimize=ReleaseFast"

capture env ROC_LUAJIT_HOST_CPUS=128 ./build --debug --dry-run
expect_out_has "build --debug selects Debug" "zig build roc -Doptimize=Debug"

capture env ROC_LUAJIT_HOST_CPUS=128 ./build --test --dry-run
expect_out_has "build --test builds MiniCI binaries" "zig build build-ci"

capture env ROC_LUAJIT_HOST_CPUS=128 ROC_LUAJIT_ZIG_CPUS=16 ./build --dry-run
expect_out_has "ROC_LUAJIT_ZIG_CPUS overrides the cap" "taskset -c 0-15"

capture env ROC_LUAJIT_HOST_CPUS=4 ./build --dry-run
expect_out_has "cap is clamped to host CPU count" "taskset -c 0-3"

for bad in 0 -3 abc ""; do
	capture env ROC_LUAJIT_HOST_CPUS=128 ROC_LUAJIT_ZIG_CPUS="$bad" ./build --dry-run
	expect_rc "invalid cap '$bad' is rejected" 2
	expect_err_has "invalid cap '$bad' is explained" "ROC_LUAJIT_ZIG_CPUS"
done

capture env ROC_LUAJIT_HOST_CPUS=128 ./build --bogus
expect_rc "unknown build option is rejected" 2
expect_err_has "unknown build option is named" "--bogus"

capture ./build --help
expect_rc "build --help succeeds" 0
expect_out_has "build --help documents the cap" "ROC_LUAJIT_ZIG_CPUS"

capture env ROC_LUAJIT_HOST_CPUS=128 ./test-all --dry-run
expect_rc "test-all dry run succeeds" 0
expect_out_has "test-all runs MiniCI under the cap" "taskset -c 0-31 zig build minici"
expect_out_has "test-all bounds MiniCI build jobs" "MINICI_MAX_CPUS=8"
expect_out_has "test-all runs the LuaJIT backend suite" "luajit_backend/tests/run"

capture env ROC_LUAJIT_HOST_CPUS=128 ./test-all --luajit-only --dry-run
expect_rc "test-all --luajit-only dry run succeeds" 0
case "$out" in *"zig build minici"*) fail "--luajit-only skips MiniCI" ;; *) pass "--luajit-only skips MiniCI" ;; esac

capture ./test-all --help
expect_rc "test-all --help succeeds" 0

if [ "$failures" -eq 0 ]; then echo "wrappers: all passed"; else echo "wrappers: $failures failed"; fi
exit "$failures"
