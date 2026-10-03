import sys
def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)
total = 0
for _ in sys.argv[1:]:
    total += fib(27 + total % 1)
print(total)
