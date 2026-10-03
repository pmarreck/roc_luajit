import sys
n = (len(sys.argv) - 1) * 50000
xs = list(range(n))
ys = [y for y in (x * 3 + 1 for x in xs) if y % 2 == 0]
print(sum(ys))
