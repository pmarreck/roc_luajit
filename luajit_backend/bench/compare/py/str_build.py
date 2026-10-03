import sys
n = (len(sys.argv) - 1) * 50000
# Python strings are immutable with no amortized append (`s += t` copies), so
# the idiomatic linear build is a list of parts joined once.
s = "".join([str(i) for i in range(n)])
print(len(s.encode()))
