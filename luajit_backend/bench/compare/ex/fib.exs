defmodule Fib do
  def fib(n) when n < 2, do: n
  def fib(n), do: fib(n - 1) + fib(n - 2)
end
total = Enum.reduce(System.argv(), 0, fn _, acc -> acc + Fib.fib(27 + rem(acc, 1)) end)
IO.puts(total)
