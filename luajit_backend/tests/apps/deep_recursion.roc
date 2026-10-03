# Non-tail recursion 50,000 calls deep (10,000 per argument, so the depth is
# a runtime value the compiler cannot fold). Native Roc runs it within its
# stack; LuaJIT's per-coroutine stack is far smaller.
sum : U64 -> U64
sum = |n| if n == 0 0 else n + sum(n - 1)

main! = |args| {
    echo!(U64.to_str(sum(List.len(args) * 10000)))
    Ok({})
}
