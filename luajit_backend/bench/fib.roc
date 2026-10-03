# Naive recursive Fibonacci, once per argument: call-heavy I64 code.
# complexity: O(n)
# scale: 8
fib : I64 -> I64
fib = |n| if n < 2 n else fib(n - 1) + fib(n - 2)

main! = |args| {
    total = args.fold(0, |acc, _| acc + fib(27 + acc % 1))
    echo!(I64.to_str(total))
    Ok({})
}
