n = length(System.argv()) * 50000
xs = Enum.to_list(0..(n - 1)//1)
ys = xs |> Enum.map(&(&1 * 3 + 1)) |> Enum.filter(&(rem(&1, 2) == 0))
IO.puts(Enum.sum(ys))
