# Dict inserts and lookups keyed by U64 (hashing and the Dict builtin).
# complexity: O(n)
# scale: 2
main! = |args| {
    n = List.len(args) * 5000
    d = (0.U64).until(n).fold(Dict.empty(), |acc, i| acc.insert(i, i * 2))
    hits = (0.U64).until(n).fold(0, |acc, i| match d.get(i) { Ok(v) => acc + v, Err(_) => acc })
    echo!(U64.to_str(hits))
    Ok({})
}
