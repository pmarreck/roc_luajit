# Integer.from_le_bytes for every width, signed and unsigned, at boundary
# values, at nonzero offsets, and one byte short (OutOfBounds). `k` is 0 at
# runtime, so nothing folds.
main! = |args| {
	k = List.len(args)
	ones = [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255].take_first(17 + k)
	high = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128].concat([7]).take_first(17 + k)
	mixed = [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x08, 0x01]
	echo!("u16 ${Str.inspect(U16.from_le_bytes(ones, k))} ${Str.inspect(U16.from_le_bytes(mixed, 1 + k))} ${Str.inspect(U16.from_le_bytes(mixed, 16 + k))}")
	echo!("i16 ${Str.inspect(I16.from_le_bytes(ones, k))} ${Str.inspect(I16.from_le_bytes(high, 14 + k))} ${Str.inspect(I16.from_le_bytes(mixed, 7 + k))}")
	echo!("u32 ${Str.inspect(U32.from_le_bytes(ones, k))} ${Str.inspect(U32.from_le_bytes(mixed, 3 + k))} ${Str.inspect(U32.from_le_bytes(mixed, 14 + k))}")
	echo!("i32 ${Str.inspect(I32.from_le_bytes(ones, k))} ${Str.inspect(I32.from_le_bytes(high, 12 + k))} ${Str.inspect(I32.from_le_bytes(mixed, 8 + k))}")
	echo!("u64 ${Str.inspect(U64.from_le_bytes(ones, k))} ${Str.inspect(U64.from_le_bytes(mixed, k))} ${Str.inspect(U64.from_le_bytes(mixed, 9 + k))} ${Str.inspect(U64.from_le_bytes(mixed, 10 + k))}")
	echo!("i64 ${Str.inspect(I64.from_le_bytes(ones, k))} ${Str.inspect(I64.from_le_bytes(high, 8 + k))} ${Str.inspect(I64.from_le_bytes(mixed, 8 + k))} ${Str.inspect(I64.from_le_bytes([1, 0, 0, 0, 0, 0, 32, 0], k))}")
	echo!("u128 ${Str.inspect(U128.from_le_bytes(ones, k))} ${Str.inspect(U128.from_le_bytes(mixed, 1 + k))} ${Str.inspect(U128.from_le_bytes(mixed, 2 + k))}")
	echo!("i128 ${Str.inspect(I128.from_le_bytes(ones, k))} ${Str.inspect(I128.from_le_bytes(high, k))} ${Str.inspect(I128.from_le_bytes(mixed, k))}")
	Ok({})
}
