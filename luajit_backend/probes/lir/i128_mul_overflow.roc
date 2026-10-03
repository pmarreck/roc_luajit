# Zig 0.16.0 Debug (self-hosted x86_64) misses this i128 multiplication
# overflow; ReleaseSafe/ReleaseFast report it. The exact product is
# -345120681902311694636179861144834699802, outside I128.
main! = |args| {
	a = 19945398355856076541.I128 + List.len(args).to_i128()
	b = -17303273454098869922.I128
	echo!(Str.inspect(a * b))
	Ok({})
}
