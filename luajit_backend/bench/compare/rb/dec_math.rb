# Roc's Dec: an integer scaled by 10^18; multiply and divide truncate toward zero.
ONE = 10**18
def mul(a, b)
  p = a * b
  p >= 0 ? p / ONE : -((-p) / ONE)
end
def div(a, b)
  q = a.abs * ONE / b.abs
  (a >= 0) == (b >= 0) ? q : -q
end
def to_str(d)
  whole, frac = d.abs.divmod(ONE)
  f = frac.to_s.rjust(18, "0").sub(/0+\z/, "")
  "#{d < 0 ? '-' : ''}#{whole}.#{f.empty? ? '0' : f}"
end
n = ARGV.length * 10000
total = 0
one_half = 15 * ONE / 10
three = 3 * ONE
n.times { |i| total += div(mul(i * ONE, one_half), three) }
puts to_str(total)
