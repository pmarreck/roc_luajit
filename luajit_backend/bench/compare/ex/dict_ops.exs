n = length(System.argv()) * 5000
range = 0..(n - 1)//1
d = Enum.reduce(range, %{}, fn i, acc -> Map.put(acc, i, i * 2) end)
hits = Enum.reduce(range, 0, fn i, acc ->
  case Map.fetch(d, i) do
    {:ok, v} -> acc + v
    :error -> acc
  end
end)
IO.puts(hits)
