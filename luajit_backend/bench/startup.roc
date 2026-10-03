# Load and run a trivial program: prelude load and chunk compile cost.
# complexity: O(1)
# scale: 1
main! = |args| {
    echo!("hello ${U64.to_str(List.len(args))}")
    Ok({})
}
