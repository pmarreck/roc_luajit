import sys
n = (len(sys.argv) - 1) * 5000
d = {}
for i in range(n):
    d[i] = i * 2
hits = 0
for i in range(n):
    v = d.get(i)
    if v is not None:
        hits += v
print(hits)
