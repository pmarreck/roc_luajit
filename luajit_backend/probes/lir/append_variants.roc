# Shapes where a static uniqueness proof may be unavailable.
rec_build = |acc, i, n| if i >= n acc else rec_build(acc.append(i), i + 1, n)

set_all = |list| {
	var $l = list
	var $i = 0.U64
	while $i < $l.len() {
		$l = match $l.set($i, 7) {
			Ok(next) => next
			Err(_) => $l
		}
		$i = $i + 1
	}
	$l
}

dict_build = |n| {
	var $d = Dict.empty()
	var $i = 0.U64
	while $i < n {
		$d = $d.insert($i, $i)
		$i = $i + 1
	}
	$d
}

keep : (List(U64), U64) -> List(U64)
keep = |pair| pair.0.append(pair.1)

pair_build = |n| {
	var $p = ([], 0.U64)
	var $i = 0.U64
	while $i < n {
		$p = (keep($p), $i)
		$i = $i + 1
	}
	$p.0
}

main! = |args| {
	n = List.len(args)
	echo!(Str.inspect(rec_build([], 0, n).len()))
	echo!(Str.inspect(set_all(List.repeat(1.U64, n)).len()))
	echo!(Str.inspect(dict_build(n).len()))
	echo!(Str.inspect(pair_build(n).len()))
	Ok({})
}
