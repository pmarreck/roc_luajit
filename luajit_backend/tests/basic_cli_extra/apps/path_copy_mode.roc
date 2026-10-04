## Path.copy! keeps the source's permission bits: fixtures/tree_ok/file is
## executable, and so is its copy. Separate from path_ops because the WASI
## host cannot see permission bits (basic_cli_cases.lua lists it there).
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.OsStr
import pf.Path
import pf.Stdout

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Path.create_all!(Path.unix("out"))?
	Path.copy!(Path.unix("fixtures/tree_ok/file"), Path.unix("out/f1"))?
	Stdout.line!("copied mode is executable: ${Str.inspect(Path.is_executable!(Path.unix("out/f1")))}")?
	Ok({})
}
