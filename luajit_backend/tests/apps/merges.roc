# Branches that merge again, with no loop or recursion: every `goto` in the
# emitted code must jump forward (luajit_backend/tests/emitted_layout).
pick : I64, I64 -> Try(I64, [Neg, Big])
pick = |a, b|
    if a < 0 {
        Err(Neg)
    } else {
        match b % 3 {
            0 => if a > 100 Err(Big) else Ok(a + b)
            1 => Ok(a * 2)
            _ => if b > 50 Ok(b) else Err(Big)
        }
    }

score : I64, I64 -> I64
score = |a, b|
    match pick(a, b) {
        Ok(v) => if v > 10 v - 10 else v + 1
        Err(Neg) => 0 - 1
        Err(Big) => match a % 2 {
            0 => 7
            _ => if b > 3 8 else 9
        }
    }

main! = |args| {
    n = U64.to_i64_wrap(List.len(args))
    echo!(I64.to_str(score(n, n * 7) + score(n - 9, n) + score(n * 40, n + 2) + score(n, 58)))
    Ok({})
}
