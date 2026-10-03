# List building, map, filter and fold over U64 (allocation and in-place updates).
# complexity: O(n)
# scale: 2
main! = |args| {
    n = List.len(args) * 50000
    xs : List(U64)
    xs = (0.U64).until(n).collect()
    ys = xs.map(|x| x * 3 + 1).keep_if(|x| x % 2 == 0)
    echo!(U64.to_str(ys.fold(0, |acc, x| acc + x)))
    Ok({})
}
