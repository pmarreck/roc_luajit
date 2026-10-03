def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)
total = 0
ARGV.each { total += fib(27 + total % 1) }
puts total
