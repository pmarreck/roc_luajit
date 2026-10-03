# Checked integer addition and subtraction (they crash on overflow) on I64,
# U64, I32, U8 and I8, including results next to 2^53, where the LuaJIT
# backend's inline fast path hands over to the runtime. `k` is 0 at runtime,
# so nothing folds.
main! = |args| {
	k = List.len(args)
	ki = k.to_i64_wrap()

	near = 9007199254740990 + ki
	echo!("i64 ${(near + 1).to_str()} ${(near + 2).to_str()} ${(near + 3).to_str()} ${(0 - near - 2).to_str()} ${(0 - near - 3).to_str()}")
	echo!("i64 small ${(ki + 40 - 2).to_str()} ${(ki - 7).to_str()}")

	big = 9007199254740990 + k
	echo!("u64 ${(big + 1).to_str()} ${(big + 2).to_str()} ${(big + 5).to_str()} ${(big + 5 - 4).to_str()} ${(k + 3 - 1).to_str()}")

	i32 = 2147483640 + k.to_i32_wrap()
	echo!("i32 ${(i32 + 7).to_str()} ${(0 - i32 - 8).to_str()}")

	u8 = 250 + k.to_u8_wrap()
	echo!("u8 ${(u8 + 5).to_str()} ${(u8 - 250).to_str()}")

	i8 = -120 + k.to_i8_wrap()
	echo!("i8 ${(i8 - 8).to_str()} ${(i8 + 127).to_str()} ${(i8 + 127 - 7).to_str()}")
	Ok({})
}
