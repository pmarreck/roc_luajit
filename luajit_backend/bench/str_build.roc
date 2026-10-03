# String building by repeated concatenation and number formatting.
# complexity: O(n)
# scale: 2
main! = |args| {
    n = List.len(args) * 50000
    s = (0.U64).until(n).fold("", |acc, i| Str.concat(acc, U64.to_str(i)))
    echo!(U64.to_str(Str.count_utf8_bytes(s)))
    Ok({})
}
