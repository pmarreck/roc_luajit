n = ARGV.length * 50000
s = +""
n.times { |i| s << i.to_s }
puts s.bytesize
