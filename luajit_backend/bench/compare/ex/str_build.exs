n = length(System.argv()) * 50000
s = Enum.reduce(0..(n - 1)//1, "", fn i, acc -> acc <> Integer.to_string(i) end)
IO.puts(byte_size(s))
