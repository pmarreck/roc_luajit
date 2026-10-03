# A thirty-variant error crossing into tables (list elements) at many sites:
# its materialization must be emitted once, not once per site
# (luajit_backend/tests/emitted_layout check 6).
Problem : [P0, P1, P2, P3, P4, P5, P6, P7, P8, P9, P10, P11, P12, P13, P14, P15, P16, P17, P18, P19, P20, P21, P22, P23, P24, P25, P26, P27, P28, P29(Str)]

check : U64 -> Try(U64, Problem)
check = |n|
    if n == 7 {
        Err(P29("seven"))
    } else if n > 20 {
        Err(P3)
    } else if n == 5 {
        Err(P28)
    } else {
        Ok(n)
    }

main! = |args| {
    k = List.len(args)
    results = [check(k + 1), check(k + 5), check(k + 7), check(k + 21), check(k + 2), check(k + 3), check(k + 4), check(k + 6), check(k + 8), check(k + 9), check(k + 10), check(k + 11), check(k + 12), check(k + 13), check(k + 14), check(k + 15)]
    oks = results.keep_if(|r| r.is_ok()).len()
    echo!("oks: ${oks.to_str()}\n")
    echo!("${Str.inspect(results.get(1))} ${Str.inspect(results.get(2))} ${Str.inspect(results.get(3))}\n")
    Ok({})
}
