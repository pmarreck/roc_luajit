## Tcp listeners and streams over loopback, served and connected by this one
## program: accept and read deadlines, zero timeouts, delimiter, exact and
## bounded reads, refused and in-use addresses, closed listeners, and end of
## file once the peer's last Stream reference is released. Results are printed
## with Str.inspect for a line-by-line comparison of a native run and a LuaJIT
## run; port numbers are never printed.
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.OsStr
import pf.Stdout
import pf.Tcp

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	listener = Tcp.listen!("127.0.0.1", 0, 1000)?
	port = listener.local_port!()?
	show!("port assigned", port != 0)?
	show!("listen on the same port", Tcp.listen!("127.0.0.1", port, 1000).map_ok(|_| {}))?
	show!("accept with timeout 0", listener.accept!(0).map_ok(|_| {}))?
	show!("accept times out", listener.accept!(50).map_ok(|_| {}))?

	client = Tcp.connect!("127.0.0.1", port, 1000)?
	server = listener.accept!(1000)?
	show!("write", client.write_utf8!("hello|world\nrest", 1000))?
	show!("read_until", server.read_until!(124, 100, 1000))?
	show!("read_line", server.read_line!(100, 1000))?
	show!("read_up_to", server.read_up_to!(100, 1000))?
	show!("read_up_to zero bytes", server.read_up_to!(0, 1000))?
	show!("read_exactly times out", server.read_exactly!(4, 100))?
	show!("read with timeout 0", server.read_up_to!(4, 0))?
	show!("write with timeout 0", client.write!([1], 0))?
	show!("write abcdef", client.write_utf8!("abcdef", 1000))?
	show!("read_until over its limit", server.read_until!(124, 3, 1000))?
	show!("read_exactly", server.read_exactly!(3, 1000))?
	show!("reply", server.write_utf8!("bye", 1000))?
	show!("client reads reply", client.read_exactly!(3, 1000))?

	# localhost may resolve to ::1 first; the IPv4 listener answers the next address.
	other = Tcp.connect!("localhost", port, 1000)?
	accepted = listener.accept!(1000)?
	show!("localhost write", other.write_utf8!("x", 1000))?
	show!("localhost read", accepted.read_up_to!(10, 1000))?

	# `other` is not used again, so its socket closes here: end of file.
	show!("read after the peer closed", accepted.read_up_to!(10, 1000))?
	show!("read_exactly after the peer closed", accepted.read_exactly!(1, 1000))?

	show!("close listener", listener.close!())?
	show!("local_port after close", listener.local_port!())?
	show!("accept after close", listener.accept!(10).map_ok(|_| {}))?
	show!("close again", listener.close!())?
	show!("connect refused", Tcp.connect!("127.0.0.1", port, 1000).map_ok(|_| {}))?
	show!("connect with timeout 0", Tcp.connect!("127.0.0.1", port, 0).map_ok(|_| {}))?
	# 192.0.2.1 (TEST-NET-1) is never this machine's address, so bind fails without
	# a name lookup, whose outcome would depend on the resolver setup.
	show!("listen on an address that is not this machine's", Tcp.listen!("192.0.2.1", 0, 1000).map_ok(|_| {}))?
	Ok({})
}
