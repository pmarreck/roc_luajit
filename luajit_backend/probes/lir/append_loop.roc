build = |n| {
	var $acc = []
	var $i = 0.U64
	while $i < n {
		$acc = $acc.append($i)
		$i = $i + 1
	}
	$acc
}

main! = |args| {
	echo!(Str.inspect(build(List.len(args)).len()))
	Ok({})
}
