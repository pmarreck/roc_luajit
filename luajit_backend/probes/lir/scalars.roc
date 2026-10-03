add_one = |x| x + 1.I64

pick = |b, x| if b x else 0.I64

main! = |_args| {
	n = add_one(41.I64)
	echo!(Str.inspect(pick(n > 0.I64, n)))
	Ok({})
}
