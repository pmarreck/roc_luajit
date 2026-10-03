n = ARGV.length * 5000
d = {}
n.times { |i| d[i] = i * 2 }
hits = 0
n.times do |i|
  v = d[i]
  hits += v if v
end
puts hits
