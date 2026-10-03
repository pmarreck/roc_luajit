## Native resources follow the Roc box: freeing the last reference to a Child
## terminates it (basic-cli's resources.rs finalizer), so a dropped child never
## finishes its work, while a child kept alive does. Runs in a copy of
## luajit_backend/tests/basic_cli_extra and writes markers under out/.
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Sleep
import pf.Stdout

later = |marker| Cmd.new("sh").args_str(["-c", "sleep 0.3; echo done > ${marker}"])

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	Path.create_all!(Path.unix("out"))?

	# The child's only reference ends after pid!, so it is released here.
	dropped = later("out/dropped").spawn!() ? |e| SpawnFailed(e)
	Stdout.line!("dropped child started: ${Str.inspect(dropped.pid!().is_ok())}")?

	kept = later("out/kept").spawn!() ? |e| SpawnFailed(e)
	Sleep.millis!(800)
	Stdout.line!("dropped child finished: ${Str.inspect(Path.exists!(Path.unix("out/dropped")))}")?
	Stdout.line!("kept child finished: ${Str.inspect(Path.exists!(Path.unix("out/kept")))}")?
	Stdout.line!("kept child: ${Str.inspect(kept.wait!())}")
}
