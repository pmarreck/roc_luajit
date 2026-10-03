# Roc's Dec: an integer scaled by 10^18; multiply and divide truncate toward zero.
import sys
ONE = 10 ** 18
def mul(a, b):
    p = a * b
    return p // ONE if p >= 0 else -((-p) // ONE)
def div(a, b):
    q = abs(a) * ONE // abs(b)
    return q if (a >= 0) == (b >= 0) else -q
def to_str(d):
    sign = "-" if d < 0 else ""
    whole, frac = divmod(abs(d), ONE)
    return f"{sign}{whole}.{(str(frac).rjust(18, '0').rstrip('0') or '0')}"
n = (len(sys.argv) - 1) * 10000
total = 0
one_half, three = 15 * ONE // 10, 3 * ONE
for i in range(n):
    total += div(mul(i * ONE, one_half), three)
print(to_str(total))
