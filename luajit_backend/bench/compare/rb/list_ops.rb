n = ARGV.length * 50000
xs = (0...n).to_a
ys = xs.map { |x| x * 3 + 1 }.select { |x| x % 2 == 0 }
puts ys.sum
