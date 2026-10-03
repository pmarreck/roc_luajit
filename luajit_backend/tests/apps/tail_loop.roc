# A tail-recursive loop: its back edge must be a loop LuaJIT compiles
# (luajit_backend/tests/emitted_layout).
sum_to : I64, I64, I64 -> I64
sum_to = |i, n, acc| if i > n acc else sum_to(i + 1, n, acc + i % 7)

main! = |args| {
    n = U64.to_i64_wrap(List.len(args)) * 200000
    echo!(I64.to_str(sum_to(0, n, 0)))
    Ok({})
}
