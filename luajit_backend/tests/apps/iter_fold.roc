# A fold over a range iterator: the iterator's state records and tags are
# carried around the loop, and must not be allocated per iteration
# (luajit_backend/tests/emitted_layout).
main! = |args| {
    n = List.len(args) * 200000
    total = (0.U64).until(n).fold(0, |acc, i| acc + i % 7)
    echo!(U64.to_str(total))
    Ok({})
}
