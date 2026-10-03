# A constant recursive value whose leaf is Box({}): its static data holds a
# box of a zero-sized type (layout box_of_zst).
Tree := [Leaf(Box({})), Node(Box(Tree), U8)]

depth : Tree -> U64
depth = |t| match t {
	Leaf(_) => 0
	Node(inner, _) => 1 + depth(Box.unbox(inner))
}

tree : Tree
tree = Node(Box.box(Node(Box.box(Leaf(Box.box({}))), 2)), 1)

main! = |args| {
	t = if List.len(args) > 5 Leaf(Box.box({})) else tree
	echo!("depth: ${depth(t).to_str()}")
	Ok({})
}
