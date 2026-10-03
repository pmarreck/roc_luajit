## Child processes through Cmd: exec, exec_output, run!, spawn! and the Child
## methods, with their error cases (missing programs, nonzero exits, signals,
## timeouts, output and pending limits, merged and teed streams, interactive
## stdin and reads, closed children). Results are printed with Str.inspect so a
## native run and a LuaJIT run can be compared line by line. Process IDs are
## never printed.
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stdout

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

sh = |script| Cmd.new("sh").args_str(["-c", script])

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	# Synchronous execution.
	show!("exit code", sh("exit 3").exec_exit_code!())?
	show!("exit code of a signal", sh("kill -TERM $$").exec_exit_code!())?
	show!("missing program", Cmd.new("/does/not/exist").exec_exit_code!())?
	show!("missing program on PATH", Cmd.new("no-such-program-roc-luajit").exec_exit_code!())?
	show!("output", sh("printf out; printf err >&2").exec_output!())?
	show!("output nonzero", sh("printf out; printf err >&2; exit 4").exec_output!())?
	show!("output bytes", sh("printf '\\377a'").exec_output_bytes!())?
	show!("output bytes nonzero", sh("printf x >&2; exit 5").exec_output_bytes!())?
	Stdout.line!("before inherited output")?
	show!("inherited", Cmd.exec!("sh", ["-c", "echo via-exec"]))?
	show!("inherited failure", Cmd.exec!("sh", ["-c", "exit 6"]))?

	# Arguments, environment and working directory.
	args = [OsStr.from_str("a b"), OsStr.from_str(""), OsStr.unix_bytes([255, 42])]
	show!("raw arguments", sh("printf '%s|' \"$@\"").arg_str("script").args(args).exec_output_bytes!())?
	show!("environment override", sh("printf %s \"$ROC_LUAJIT_TEST\"").env_str("ROC_LUAJIT_TEST", "set").exec_output!())?
	cleared = Cmd.new("/usr/bin/env").clear_envs().env_str("B", "2").env_str("A", "1").env_str("C", "3")
	show!("cleared environment in order", cleared.exec_output!())?
	show!("working directory", sh("pwd").cwd(Path.unix("fixtures")).exec_output!())?
	show!("missing working directory", sh("pwd").cwd(Path.unix("missing")).exec_output!())?

	# run! with capture by default.
	show!("run", sh("printf hi; printf err >&2; exit 2").run!())?
	show!("run signaled", sh("kill -TERM $$").run!())?
	show!("run stdin bytes", sh("cat").stdin(Bytes([104, 105])).run!())?
	show!("run large stdin", sh("wc -c").stdin(Bytes(List.repeat(42, 200000))).run!())?
	show!("run timeout", sh("printf early; sleep 5").timeout_ms(200).run!())?
	show!("run output limit", sh("printf 0123456789; printf abc >&2").output_limit(5).run!())?
	show!("run merged", sh("printf a; printf b >&2; printf c; printf d >&2").merge_stderr(Bool.True).run!())?
	show!("run merged into null", sh("printf a; printf b >&2").merge_stderr(Bool.True).stdout(Null).run!())?
	show!("run null streams", sh("printf a; printf b >&2").stdout(Null).stderr(Null).run!())?
	show!("run tee", sh("printf 'teed\\n'").stdout(Tee).run!())?
	show!("run inherit", sh("printf 'inherited\\n'").stdout(Inherit).run!())?
	show!("run tree timeout", sh("sleep 30 & exit 0").timeout_ms(200).manage_tree(Bool.True).run!())?
	show!("run large output both streams", sh("(head -c 200000 /dev/zero >&2) & head -c 100000 /dev/zero; wait").run!().map_ok(|o| (o.status, o.stdout_bytes.len(), o.stderr_bytes.len())))?

	# spawn! and the Child methods.
	echo = sh("cat").stdin(Pipe).stdout(Pipe).spawn!() ? |e| SpawnFailed(e)
	show!("try_wait while running", echo.try_wait!())?
	show!("write", echo.write!([104, 101, 108, 108, 111], 1000))?
	show!("close_stdin", echo.close_stdin!())?
	show!("close_stdin again", echo.close_stdin!())?
	show!("read 2", echo.read!(2, 1000))?
	show!("read 2", echo.read!(2, 1000))?
	show!("read 2", echo.read!(2, 1000))?
	show!("read 2", echo.read!(2, 1000))?
	show!("read zero", echo.read!(0, 1000))?
	show!("wait", echo.wait!())?
	show!("wait again", echo.wait!())?
	show!("write after wait", echo.write!([1], 1000))?
	show!("close", echo.close!())?
	show!("close again", echo.close!())?
	show!("pid after close", echo.pid!())?
	show!("wait after close", echo.wait!())?

	silent = sh("sleep 5").stdout(Pipe).spawn!() ? |e| SpawnFailed(e)
	show!("pid while open", silent.pid!().is_ok())?
	show!("read timeout", silent.read!(10, 50))?
	show!("try_wait", silent.try_wait!())?
	show!("kill", silent.kill!())?
	show!("wait killed", silent.wait!())?
	show!("try_wait killed", silent.try_wait!())?
	show!("close killed", silent.close!())?

	streams = sh("printf o; sleep 0.1; printf e >&2").stdout(Pipe).stderr(Pipe).spawn!() ? |e| SpawnFailed(e)
	show!("event 1", streams.read!(10, 2000))?
	show!("event 2", streams.read!(10, 2000))?
	show!("event 3", streams.read!(10, 2000))?
	show!("event 3 again", streams.read!(10, 2000))?
	show!("streams wait", streams.wait!())?

	bounded = sh("printf 0123456789").stdout(Pipe).pending_limit(4).spawn!() ? |e| SpawnFailed(e)
	show!("pending limit wait", bounded.wait!())?
	show!("pending limit read", bounded.read!(100, 1000))?
	show!("pending limit read end", bounded.read!(100, 1000))?
	show!("pending limit close", bounded.close!())?

	show!("spawn missing", Cmd.new("/does/not/exist").spawn!().map_ok(|_| {}))?

	show!("available sh", Cmd.check_available!("sh"))?
	show!("available missing", Cmd.check_available!("no-such-program-roc-luajit"))?
	Ok({})
}
