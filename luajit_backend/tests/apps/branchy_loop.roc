# A tail-recursive loop whose body branches and merges (several segments): the
# whole body must sit inside the loop LuaJIT traces (luajit_backend/tests/emitted_layout).
walk : I64, I64, I64 -> I64
walk = |i, n, acc|
    if i > n {
        acc
    } else {
        step = match i % 3 {
            0 => if i % 2 == 0 i // 2 else i * 3
            1 => i + 1
            _ => if acc > 1000 0 - 1 else 2
        }
        walk(i + 1, n, (acc + step) % 1000003)
    }

main! = |args| {
    n = U64.to_i64_wrap(List.len(args)) * 200000
    echo!(I64.to_str(walk(0, n, 0)))
    Ok({})
}
