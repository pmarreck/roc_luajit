# Integer to_str results used through Str operations, at values where a
# number printed by Lua's own tostring would differ from Roc's formatting
# (1e+15, 9.007199254741e+15) and at 64-bit extremes.
main! = |_args| {
    strs = [
        I64.to_str(0),
        I64.to_str(-1),
        I64.to_str(1000000000000000),
        I64.to_str(-9007199254740991),
        I64.to_str(123456789012345678),
        I64.to_str(-9223372036854775808),
        U64.to_str(9007199254740993),
        U64.to_str(18446744073709551615),
        I32.to_str(-2147483648),
        U8.to_str(255),
    ]
    joined = Str.join_with(strs, ",")
    echo!(joined)
    echo!(U64.to_str(Str.count_utf8_bytes(joined)))
    List.for_each!(strs, |s| {
        echo!(Str.concat(Str.concat("[", s), "]"))
        echo!(U64.to_str(Str.count_utf8_bytes(s)))
        echo!(if s == "1000000000000000" "eq" else "ne")
        echo!(if Str.contains(s, "00") "has00" else "no00")
        echo!(if Str.starts_with(s, "-") "neg" else "pos")
        echo!(U64.to_str(List.len(Str.to_utf8(s))))
        echo!(Str.concat(s, s))
        echo!(Str.repeat(s, 2))
        match I64.from_str(s) {
            Ok(n) => echo!(I64.to_str(n + 0))
            Err(_) => echo!("parse failed")
        }
    })
    d = Dict.insert(Dict.empty(), I64.to_str(1000000000000000), "found")
    echo!(Dict.get(d, "1000000000000000") ?? "missing")
    Ok({})
}
