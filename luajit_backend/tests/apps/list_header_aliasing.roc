# List values whose header the LuaJIT runtime may update in place (a uniquely
# owned allocation consumed by append, sublist, drop or append-sublist) next
# to values that must stay unchanged: originals kept after a derived list is
# built, zero-sized and empty lists shared between names, lists stored in
# records and lists, a list concatenated with itself. `k` is 0 at runtime, so
# nothing folds.
show : List(U64) -> Str
show = |l| Str.inspect(l)

main! = |args| {
	k = List.len(args)

	# A fresh list appended to repeatedly: unique, updated in place.
	grown = (0.U64).until(5 + k).fold([], |acc, i| acc.append(i * 10))
	echo!("grown ${show(grown)}")

	# The original stays as it was after each derived list.
	base = [1, 2, 3].map(|x| x + k)
	appended = base.append(4)
	dropped = base.drop_first(1)
	prefix = base.take_first(2)
	echo!("base ${show(base)} appended ${show(appended)} dropped ${show(dropped)} prefix ${show(prefix)}")

	# Zero-sized and empty lists shared between names.
	units = List.repeat({}, 3 + k)
	more_units = units.append({})
	echo!("units ${List.len(units).to_str()} more ${List.len(more_units).to_str()}")
	empty : List(U64)
	empty = []
	one = empty.append(7 + k)
	two = empty.append(8 + k)
	echo!("empty ${show(empty)} one ${show(one)} two ${show(two)}")

	# Lists inside records and lists, then extended.
	record = { items: [5, 6].map(|x| x + k), tag: "r" }
	extended = record.items.append(7)
	echo!("record ${show(record.items)} extended ${show(extended)}")
	nested = [[1, 2], [3]].map(|l| l.map(|x| x + k))
	first = match nested.first() { Ok(l) => l, Err(_) => [] }
	echo!("nested ${Str.inspect(nested)} first appended ${show(first.append(9))}")

	# A list concatenated with itself and with its own sublist.
	twice = base.concat(base)
	tail = twice.drop_first(4)
	echo!("twice ${show(twice)} tail ${show(tail)} base ${show(base)}")

	# A unique list consumed by successive in-place steps, each step's result
	# only used by the next.
	stepped = (0.U64).until(8 + k).fold([], |acc, i| acc.append(i)).drop_first(2).take_first(4).append(99)
	echo!("stepped ${show(stepped)}")
	Ok({})
}
