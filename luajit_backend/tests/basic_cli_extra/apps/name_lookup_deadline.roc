## Name lookups that never get an answer (the dns helper server reads queries
## and stays silent), bounded by each call's deadline as basic-cli's
## resolve_with_deadline and hyper's request timeout bound them.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import pf.Http
import pf.OsStr
import pf.Stdout
import pf.Tcp
import http.Request

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	show!("connect to an unanswered name", Tcp.connect!("slow.test", 80, 300).map_ok(|_| {}))?
	show!("listen on an unanswered name", Tcp.listen!("slow.test", 0, 300).map_ok(|_| {}))?
	show!("http to an unanswered name", Http.send!(Request.from_method(GET).with_uri("http://slow.test/").with_timeout(TimeoutMilliseconds(300))).map_ok(|_| {}))?
	show!("connect to localhost still resolves", Tcp.connect!("localhost", 1, 1000).map_ok(|_| {}))?
	Ok({})
}
