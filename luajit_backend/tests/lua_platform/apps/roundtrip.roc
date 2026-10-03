## Canonical values through Lua and back (`return ...`) unchanged, over
## generated nested values (Num never integral, no Nil table values: Lua
## would canonicalize those, which eval_basics covers); stdin lines; and a
## nonzero exit status. Must print the same natively and on LuaJIT.
app [main!] { pf: platform "../../../platforms/lua/main.roc" }

import pf.Lua
import pf.Stdout
import pf.Stdin

# Deterministic pseudo-random values (a 64-bit LCG), nested to depth 3.
next : U64 -> U64
next = |seed| seed.times_wrap(6364136223846793005).plus_wrap(1442695040888963407)

gen : U64, U64, Bool -> (Lua.Value, U64)
gen = |seed, depth, nil_ok| {
	s = next(seed)
	pick = (s // 4294967296) % (if depth >= 3 6 else 7)
	match pick {
		0 => (if nil_ok Nil else Str(""), s)
		1 => (Bool(s % 2 == 0), s)
		2 => (Int((s // 7).to_i64_wrap()), s)
		3 => (Num((s % 100000).to_f64() / 8.0 + 0.0625), s)
		4 => (Str("s${(s % 1000).to_str()}✓"), s)
		5 => (Int((s % 2000).to_i64_wrap() - 1000), s)
		_ => {
			count = (s // 65536) % 4
			var $pairs = []
			var $seed = s
			var $i = 0
			while $i < count {
				$pairs = $pairs.append((Int($i.to_i64_wrap() + 1), gen($seed, depth + 1, False).0))
				$seed = next($seed.plus_wrap($i))
				$i = $i + 1
			}
			(Table($pairs), $seed)
		}
	}
}

main! = |_args| {
	var $seed = 42
	var $same = 0.U64
	var $i = 0
	while $i < 200 {
		(value, after) = gen($seed, 0, True)
		$seed = after
		back = Lua.eval!("return ...", [value])
		if Str.inspect(back) == Str.inspect(Ok(value)) {
			$same = $same + 1
		} else {
			Stdout.line!("differs: ${Str.inspect(value)} -> ${Str.inspect(back)}")
		}
		$i = $i + 1
	}
	Stdout.line!("round trips unchanged: ${$same.to_str()} of 200")
	Stdout.line!("stdin 1: ${Str.inspect(Stdin.line!())}")
	Stdout.line!("stdin 2: ${Str.inspect(Stdin.line!())}")
	Stdout.line!("stdin 3: ${Str.inspect(Stdin.line!())}")
	Err(Exit(3))
}
