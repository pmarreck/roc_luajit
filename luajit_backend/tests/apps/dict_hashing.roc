# Dict and Set over several key types, so every hasher write the LuaJIT
# backend lowers (integers, strings, floats, wide integers, records) runs.
# emitted_layout checks that the Hasher state never goes through a table.
main! = |args| {
	k = List.len(args)
	ints = (0.U64).until(200 + k).fold(Dict.empty(), |acc, i| acc.insert(i, i * 3))
	echo!("ints ${ints.len().to_str()} ${Str.inspect(ints.get(150))} ${Str.inspect(ints.get(999))}")
	strs = ["a", "bb", "ccc", "a", "dddd"].fold(Dict.empty(), |acc, s| acc.insert(s, s.count_utf8_bytes()))
	echo!("strs ${strs.len().to_str()} ${Str.inspect(strs.get("ccc"))}")
	wide = [1.I128, -1, 170141183460469231731687303715884105727].fold(Set.empty(), |acc, v| acc.insert(v))
	echo!("wide ${wide.len().to_str()} ${Str.inspect(wide.contains(-1))}")
	decs = [1.5.Dec, 2.25, 1.5].fold(Set.empty(), |acc, v| acc.insert(v))
	echo!("decs ${decs.len().to_str()}")
	pairs = [{ x: 1.I32, y: 2.I32 }, { x: 2, y: 1 }, { x: 1, y: 2 }].fold(Set.empty(), |acc, p| acc.insert(p))
	echo!("pairs ${pairs.len().to_str()}")
	Ok({})
}
