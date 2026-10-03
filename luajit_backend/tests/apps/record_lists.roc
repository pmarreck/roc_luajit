# Lists whose elements are records, tuples and tag unions, through every list
# operation, both while a list is uniquely owned (updated in place) and while
# another value still shares it (copied). The LuaJIT backend stores such
# elements as their leaves (flat list storage); emitted_layout checks that
# these lists use the flat modules, echo_conformance that the output agrees
# with the native build. `k` is 0 at runtime, so nothing folds.
Shape : [Circle(U64), Label(Str), Empty]

Pt : { x : I32, y : I32 }
Named : { name : Str, bytes : List(U8) }

show_pts : List(Pt) -> Str
show_pts = |pts| Str.join_with(pts.map(|p| "${p.x.to_str()}/${p.y.to_str()}"), ",")
show_named : List(Named) -> Str
show_named = |ns| Str.join_with(ns.map(|n| "${n.name}:${Str.inspect(n.bytes)}"), ",")
show_shapes : List(Shape) -> Str
show_shapes = |ss| Str.join_with(ss.map(|s| match s {
	Circle(r) => "C${r.to_str()}"
	Label(t) => "L${t}"
	Empty => "E"
}), ",")

main! = |args| {
	k = List.len(args)
	ki = k.to_i32_wrap()

	# Two-leaf records.
	pts = (0.U64).until(6 + k).fold([], |acc, i| acc.append({ x: i.to_i32_wrap() + ki, y: 10 - i.to_i32_wrap() }))
	echo!("pts ${show_pts(pts)} len ${pts.len().to_str()}")
	shared = pts
	appended = pts.append({ x: 99, y: 98 })
	echo!("append ${show_pts(appended)} | original ${show_pts(shared)}")
	echo!("prepend ${show_pts(pts.prepend({ x: -1, y: -2 }))}")
	echo!("concat ${show_pts(pts.concat([{ x: 7, y: 7 }, { x: 8, y: 8 }]))}")
	echo!("sublist ${show_pts(pts.sublist({ start: 1 + k, len: 3 }))}")
	echo!("drop_at ${show_pts(pts.drop_at(2 + k))}")
	echo!("swap ${Str.inspect(pts.swap(0, 5 + k).map_ok(show_pts))}")
	echo!("rev ${show_pts(pts.rev())}")
	echo!("set ${Str.inspect(pts.set(3 + k, { x: 42, y: 24 }).map_ok(show_pts))}")
	echo!("set out of bounds ${Str.inspect(pts.set(60 + k, { x: 0, y: 0 }).map_ok(show_pts))}")
	match pts.replace(1 + k, { x: 5, y: 5 }) {
		Ok(r) => echo!("replace ${show_pts(r.list)} prev ${r.prev.x.to_str()}/${r.prev.y.to_str()}")
		Err(_) => echo!("replace failed")
	}
	echo!("update ${Str.inspect(pts.update(2 + k, |p| { x: p.x * 100, y: p.y }).map_ok(show_pts))}")
	echo!("insert ${Str.inspect(pts.insert(1 + k, { x: 11, y: 11 }).map_ok(show_pts))}")
	echo!("first ${Str.inspect(pts.first())} last ${Str.inspect(pts.last())} get ${Str.inspect(pts.get(4 + k))}")
	echo!("empty first ${Str.inspect(pts.take_first(k).first())}")
	echo!("take ${show_pts(pts.take_first(2 + k))} ${show_pts(pts.take_last(2 + k))} drop ${show_pts(pts.drop_first(4 + k))} ${show_pts(pts.drop_last(4 + k))}")
	echo!("split_at ${Str.inspect(pts.split_at(2 + k))}")
	echo!("sort_with ${show_pts(pts.sort_with(|a, b| if a.y < b.y Before else if a.y > b.y After else Same))}")
	echo!("sort_by ${show_pts(pts.concat(pts).sort_by(|p| p.x))}")
	echo!("keep_if ${show_pts(pts.keep_if(|p| p.x % 2 == 0))} drop_if ${show_pts(pts.drop_if(|p| p.x % 2 == 0))}")
	echo!("eq ${Str.inspect(pts == shared)} ${Str.inspect(pts == appended)} contains ${Str.inspect(pts.contains({ x: 3, y: 7 }))}")
	echo!("release ${show_pts(pts.reserve(100 + k).release_excess_capacity())} capacity ${pts.release_excess_capacity().capacity().to_str()}")
	echo!("append_range_within ${Str.inspect(pts.append_range_within(1 + k, 2).map_ok(show_pts))}")
	echo!("copy_range_within ${Str.inspect(pts.copy_range_within(0, 3 + k, 2).map_ok(show_pts))}")
	echo!("append_sublist ${show_pts(pts.append_sublist(appended, { start: 4 + k, len: 3 }))}")
	echo!("chunks ${Str.inspect(pts.chunks_of(4 + k).map(|c| c.len()))}")
	echo!("intersperse ${show_pts(pts.take_first(3 + k).intersperse({ x: 0, y: 0 }))}")
	match pts {
		[a, b, .. as rest] => echo!("pattern ${a.x.to_str()} ${b.x.to_str()} rest ${show_pts(rest)}")
		_ => echo!("pattern none")
	}

	# Map between strides: record to record (same leaves), record to number
	# (fewer), number to record (more), record to a wider record.
	echo!("map same ${show_pts(pts.map(|p| { x: p.y, y: p.x }))}")
	echo!("map fewer ${Str.inspect(pts.map(|p| p.x + p.y))}")
	echo!("map more ${show_pts((0.I32).until(4 + ki).fold([], |acc, i| acc.append(i)).map(|i| { x: i, y: i * i }))}")
	echo!("map wider ${Str.inspect(pts.map(|p| (p.x, p.y, p.x - p.y)))}")
	echo!("map_with_index ${Str.inspect(pts.map_with_index(|p, i| { i, p }))}")

	# Building in place: a growing list of records appended and set in a loop.
	built = (0.U64).until(300 + k).fold(List.with_capacity(2), |acc, i| {
		next = acc.append({ x: i.to_i32_wrap(), y: 0 })
		match next.set(i / 2, { x: -1, y: i.to_i32_wrap() }) {
			Ok(l) => l
			Err(_) => next
		}
	})
	echo!("built ${built.len().to_str()} sum ${built.fold(0.I64, |s, p| s + p.x.to_i64() + p.y.to_i64()).to_str()}")

	# Tuples (the shape of Dict's buckets) and nested records (three leaves).
	pairs = [(1.U32, 2.U32), (3, 4), (5 + k.to_u32_wrap(), 6)]
	echo!("tuples ${Str.inspect(pairs.rev().append((7, 8)))}")
	nested = [{ p: { x: 1.I32, y: 2.I32 }, n: 3.U8 }, { p: { x: 4, y: 5 }, n: 6 }]
	echo!("nested ${Str.inspect(nested.prepend({ p: { x: 0, y: 0 }, n: 0 }).drop_at(2))}")

	# Elements holding refcounted values (Str, List), shared and modified.
	named = ["alpha", "beta", "gamma", "delta"].map(|s| { name: s, bytes: s.to_utf8().take_first(2 + k) })
	keep = named
	changed = named.set(1 + k, { name: "BETA", bytes: [1, 2, 3] }).map_ok(|l| l.rev()).ok_or([])
	echo!("named ${show_named(changed)} | kept ${show_named(keep)}")
	echo!("named sorted ${show_named(named.sort_with(|a, b| if a.name.count_utf8_bytes() < b.name.count_utf8_bytes() Before else if a.name.count_utf8_bytes() > b.name.count_utf8_bytes() After else Same))}")
	echo!("named concat ${show_named(named.drop_first(2 + k).concat(named.take_first(1 + k)))}")

	# Tag unions: variants use different leaves (unused leaves are empty).
	shapes = [Circle(3), Label("hi"), Empty, Circle(7 + k), Label("yo")]
	echo!("shapes ${show_shapes(shapes)} rev ${show_shapes(shapes.rev())} swap ${Str.inspect(shapes.swap(0, 2 + k).map_ok(show_shapes))}")
	echo!("shapes set ${Str.inspect(shapes.set(1 + k, Empty).map_ok(show_shapes))} keep ${show_shapes(shapes.keep_if(|s| s != Empty))}")
	echo!("shapes inspect ${Str.inspect(shapes.drop_last(2 + k))}")

	# Dict and Set keyed by records: their buckets and entries are tuple lists.
	d = (0.U64).until(40 + k).fold(Dict.empty(), |acc, i| acc.insert({ a: i % 7, b: i % 5 }, i))
	echo!("dict ${d.len().to_str()} ${Str.inspect(d.get({ a: 3, b: 3 }))} ${Str.inspect(d.get({ a: 9, b: 0 }))}")
	s = pts.fold(Set.empty(), |acc, p| acc.insert(p)).insert({ x: 0, y: 10 })
	echo!("set ${s.len().to_str()} ${Str.inspect(s.contains({ x: 2, y: 8 }))}")
	Ok({})
}
