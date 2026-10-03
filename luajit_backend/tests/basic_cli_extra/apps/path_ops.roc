## Path.copy!, copy_dir!, copy_dir_with!, absolute!, canonicalize! and
## Env.create_temp_dir_in!, including their error cases, printed with
## Str.inspect so a native run and a LuaJIT run can be compared line by line.
## Runs in a copy of luajit_backend/tests/basic_cli_extra (fixtures/ beside it).
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.Env
import pf.OsStr
import pf.Path
import pf.Stdout

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

# Entries in readdir order: both runs build their trees the same way on the
# same file system, so the order agrees.
listing! = |dir| Ok(Path.list!(Path.unix(dir))?.map(Path.display))

follow_new = { symlinks: Follow, destination: RequireNew }
follow_merge = { symlinks: Follow, destination: Merge }
preserve_new = { symlinks: Preserve, destination: RequireNew }
preserve_merge = { symlinks: Preserve, destination: Merge }

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	p = Path.unix
	tree = p("fixtures/tree_ok")

	# Path.copy! (a single regular file).
	show!("copy into missing dir", Path.copy!(p("fixtures/tree_ok/file"), p("out/f1")))?
	Path.create_all!(p("out"))?
	show!("copy file", Path.copy!(p("fixtures/tree_ok/file"), p("out/f1")))?
	show!("copied bytes", Path.read_utf8!(p("out/f1")))?
	show!("copied mode is executable", Path.is_executable!(p("out/f1")))?
	show!("copy over file", Path.copy!(p("fixtures/tree_ok/nested/inner"), p("out/f1")))?
	show!("overwritten bytes", Path.read_utf8!(p("out/f1")))?
	show!("copy onto itself", Path.copy!(p("out/f1"), p("out/f1")))?
	show!("copy onto itself by another name", Path.copy!(p("out/f1"), p("out/../out/f1")))?
	show!("copy a directory", Path.copy!(tree, p("out/f2")))?
	show!("copy onto a directory", Path.copy!(p("out/f1"), p("out")))?
	show!("copy missing source", Path.copy!(p("missing"), p("out/f3")))?

	# Path.copy_dir! and copy_dir_with!.
	show!("copy tree", Path.copy_dir!(tree, p("out/t1")))?
	show!("copy tree listing", listing!("out/t1"))?
	show!("followed link is a link", Path.is_sym_link!(p("out/t1/ext")))?
	show!("followed link data", Path.read_utf8!(p("out/t1/ext/data")))?
	show!("copy tree again", Path.copy_dir!(tree, p("out/t1")))?
	show!("merge tree", Path.copy_dir_with!(tree, p("out/t1"), follow_merge))?
	show!("preserve tree", Path.copy_dir_with!(tree, p("out/t2"), preserve_new))?
	show!("preserved link is a link", Path.is_sym_link!(p("out/t2/ext")))?
	show!("preserve merge again", Path.copy_dir_with!(tree, p("out/t2"), preserve_merge))?
	show!("follow merge over preserved links", Path.copy_dir_with!(tree, p("out/t2"), follow_merge))?
	show!("dangling link followed", Path.copy_dir!(p("fixtures/tree_dangling"), p("out/t3")))?
	show!("dangling link preserved", Path.copy_dir_with!(p("fixtures/tree_dangling"), p("out/t4"), preserve_new))?
	show!("dangling link preserved listing", listing!("out/t4"))?
	show!("cycle followed", Path.copy_dir!(p("fixtures/tree_cycle"), p("out/t5")))?
	show!("cycle preserved", Path.copy_dir_with!(p("fixtures/tree_cycle"), p("out/t6"), preserve_new))?
	show!("into itself", Path.copy_dir!(tree, p("fixtures/tree_ok/nested/copy")))?
	show!("onto its parent", Path.copy_dir_with!(p("fixtures/tree_ok/nested"), tree, follow_merge))?
	show!("missing parents", Path.copy_dir_with!(tree, p("out/deep/er/t7"), follow_new))?
	show!("missing parents listing", listing!("out/deep/er/t7/nested"))?
	show!("source is a file", Path.copy_dir!(p("out/f1"), p("out/t8")))?
	show!("missing source tree", Path.copy_dir!(p("missing"), p("out/t9")))?
	show!("destination is a file", Path.copy_dir_with!(tree, p("out/f1"), follow_merge))?

	# Path.absolute! and canonicalize!.
	for raw in ["rel/x/", "./a/./b", "a/../b", "/x//y/../z/", "//net/x", "///x", ".", "/", ""] {
		show!("absolute ${Str.inspect(raw)}", Path.absolute!(p(raw)))?
	}
	for raw in ["fixtures/./tree_ok/../tree_ok/ext", "out/t2/ext/data", "missing", "out/f1/x", ""] {
		show!("canonicalize ${Str.inspect(raw)}", Path.canonicalize!(p(raw)))?
	}

	# Env.create_temp_dir_in!: names are random, so only their shape is shown.
	# A relative parent is resolved against the working directory.
	made = Env.create_temp_dir_in!(p("out"), "pre-")
	match made {
		Ok(dir) => {
			name = Path.display(dir)
			show!("temp dir is absolute", Str.starts_with(name, "/"))?
			show!("temp dir prefix", Str.contains(name, "/out/pre-"))?
			show!("temp dir length", Str.count_utf8_bytes(name))?
			show!("temp dir is a dir", Path.is_dir!(dir))?
		}
		Err(e) => show!("temp dir", Err(e))?
	}
	for prefix in ["a/b", "a\\b", "x:y", "..", ".", "nul\u(0)"] {
		show!("temp dir prefix ${Str.inspect(prefix)}", Env.create_temp_dir_in!(p("out"), prefix))?
	}
	show!("temp dir in missing parent", Env.create_temp_dir_in!(p("missing"), "pre-"))?
	Ok({})
}
