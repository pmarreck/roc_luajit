# I64 and U64 values on both sides of 2^53, where the LuaJIT backend switches
# between Lua numbers and int64/uint64 cdata: arithmetic across the boundary,
# equality and ordering between the two forms, list elements, Dict keys,
# conversions and formatting. `k` is 0 at runtime, so nothing folds.
show_i : I64 -> Str
show_i = |v| v.to_str()

main! = |args| {
	k = List.len(args)
	ki = k.to_i64_wrap()

	below = 9007199254740991 + ki
	at = below + 1
	above = at + 1
	echo!("i64: ${show_i(below)} ${show_i(at)} ${show_i(above)}\n")
	echo!("back: ${show_i(above - 2)} eq ${Str.inspect(above - 2 == below)} lt ${Str.inspect(below < at)} gt ${Str.inspect(above > below)}\n")
	neg = 0 - above
	echo!("neg: ${show_i(neg)} ${show_i(neg + 3)} ${show_i(neg.abs())}\n")

	m = 94906267 + ki
	echo!("square: ${show_i(m * m)} ${show_i((m * m) // m)} ${show_i((m * m) % 1000003)}\n")
	echo!("div: ${show_i((4611686018427387904 + ki) // 3)} ${show_i((-4611686018427387904 + ki) % 7)} ${show_i(at // (0 - 2))}\n")
	echo!("wrap: ${show_i(I64.highest.plus_wrap(1 + ki))} ${show_i(above.times_wrap(1024))}\n")

	u_top = 18446744073709551615 - k
	u_mid = 9007199254740992 + k
	echo!("u64: ${u_top.to_str()} ${(u_top - u_mid).to_str()} ${(u_mid - 1).to_str()} ${(u_mid * 2).to_str()}\n")
	echo!("convert: ${above.to_u64_wrap().to_str()} ${neg.to_u64_wrap().to_str()} ${u_top.to_i64_wrap().to_str()} ${(u_mid - 1).to_i64_wrap().to_str()}\n")

	values = [below, at, above, neg, ki, 7]
	echo!("list: ${Str.inspect(values)} sum ${show_i(values.fold(0, |acc, v| acc.plus_wrap(v)))} has ${Str.inspect(values.contains(at - 1))}\n")

	dict = Dict.from_list([(below, "below"), (at, "at"), (above, "above"), (ki, "zero")])
	echo!("dict: ${Str.inspect(dict.get(9007199254740992 + ki))} ${Str.inspect(dict.get(above - 2))} ${Str.inspect(dict.get(0))} len ${dict.len().to_str()}\n")
	Ok({})
}
