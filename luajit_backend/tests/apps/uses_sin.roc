# Calls one F64 transcendental, so of the prelude modules compiled on first
# use only fmath may be compiled (luajit_backend/tests/emitted_layout).
main! = |args| {
	x = List.len(args).to_f64() + 0.5
	echo!("sin: ${x.sin().to_str()}\n")
	Ok({})
}
