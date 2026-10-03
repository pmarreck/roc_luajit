# Dec (128-bit fixed point) arithmetic in a loop: the wide-integer runtime.
# complexity: O(n)
# scale: 2
main! = |args| {
    n = List.len(args) * 10000
    total = (0.U64).until(n).fold(0.0, |acc, i| acc + U64.to_dec(i) * 1.5 / 3.0)
    echo!(Dec.to_str(total))
    Ok({})
}
