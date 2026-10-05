#!/usr/bin/env bash
# Exercise the real dependency pipeline, headerless staging, and source diagnostics.
set -eu
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
roc="$root/zig-out/bin/roc"
work="$(mktemp -d "${TMPDIR:-/tmp}/roc_luajit_driver.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cat > "$work/Main.roc" <<'ROC'
import Helper
main! = |_args| {
    echo!(Helper.message)
    Ok({})
}
ROC
printf 'module [message]\nmessage = "dependency pipeline works"\n' > "$work/Helper.roc"
(cd "$work" && "$roc" check Main.roc && "$roc" build Main.roc --output=app.lua)
luajit "$work/app.lua" > "$work/actual"
printf 'dependency pipeline works' > "$work/expected"
cmp "$work/expected" "$work/actual"
printf 'main! = |_args| { echo!(undefined_name); Ok({}) }\n' > "$work/Bad.roc"
if "$roc" check "$work/Bad.roc" > "$work/bad.log" 2>&1; then
    echo 'driver: invalid source unexpectedly passed checking' >&2; exit 1
fi
# Diagnostics must name the original input rather than its staging directory.
grep -q 'Bad.roc' "$work/bad.log"
if "$roc" build "$work/Bad.roc" --output="$work/bad.lua" >> "$work/bad.log" 2>&1; then exit 1; fi
[ ! -e "$work/bad.lua" ]
echo 'driver: relative input, imports, emission, and invalid-source diagnostics passed'

"$roc" build "$root/luajit_backend/tests/lua_platform/apps/eval_basics.roc" --output="$work/platform.lua"
(cd "$work" && env LUA_PLATFORM_TEST=set luajit "$work/platform.lua" a 'b c') > "$work/platform.out"
grep -Fq 'args: ["a", "b c"]' "$work/platform.out"
grep -Fq 'double: Ok(Int(42))' "$work/platform.out"
grep -Fq 'read: Ok("one' "$work/platform.out"
[ ! -e "$work/lua_platform_test.txt" ]
echo 'driver: explicit platform, hosted calls, and file effects passed'
