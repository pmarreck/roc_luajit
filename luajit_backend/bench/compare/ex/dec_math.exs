# Roc's Dec: an integer scaled by 10^18; multiply and divide truncate toward zero.
defmodule Dec do
  @one 1_000_000_000_000_000_000
  def one, do: @one
  def mul(a, b), do: div(a * b, @one)
  def dvd(a, b), do: div(a * @one, b)
  def to_str(d) do
    sign = if d < 0, do: "-", else: ""
    whole = div(abs(d), @one)
    frac = rem(abs(d), @one) |> Integer.to_string() |> String.pad_leading(18, "0") |> String.trim_trailing("0")
    "#{sign}#{whole}.#{if frac == "", do: "0", else: frac}"
  end
end
n = length(System.argv()) * 10000
one_half = div(15 * Dec.one(), 10)
three = 3 * Dec.one()
total = Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc + Dec.dvd(Dec.mul(i * Dec.one(), one_half), three) end)
IO.puts(Dec.to_str(total))
