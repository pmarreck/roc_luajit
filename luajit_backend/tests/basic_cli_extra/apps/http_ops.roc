## Http through basic-cli against the helper HTTP server (scripts/helper_server,
## run beside this app in a private network namespace): statuses, response
## headers (repeated, mixed case, non-ASCII), the request as the server saw it
## for each method, explicit and default content types, empty header values,
## HEAD, a timeout, a refused connection, an invalid method and a body that is
## not UTF-8. Results are printed with Str.inspect for comparison with the
## native build.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import pf.Http
import pf.OsStr
import pf.Stdout
import http.Request
import http.Response

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

base = "http://127.0.0.1:9000"

summary = |result|
	result.map_ok(|response| { status: Response.status(response), headers: Response.headers(response).len(), body: Str.from_utf8_lossy(Response.body(response)) })

send! = |method, path| Http.send!(Request.from_method(method).with_uri("${base}${path}"))

echo! = |request| Http.send!(request).map_ok(|response| Str.from_utf8_lossy(Response.body(response)))

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	show!("status 404", summary(send!(GET, "/x/status/404")))?
	show!("status 503", summary(send!(GET, "/x/status/503")))?
	show!("response headers", Http.send!(Request.from_method(GET).with_uri("${base}/x/headers")).map_ok(|response| Response.headers(response).keep_if(|h| h.name != "date")))?

	show!("GET echo", echo!(Request.from_method(GET).with_uri("${base}/x/echo?q=1")))?
	show!("POST echo, empty body", echo!(Request.from_method(POST).with_uri("${base}/x/echo")))?
	show!("PUT echo, body and headers", echo!(
		Request.from_method(PUT)
			.with_uri("${base}/x/echo")
			.add_header("X-Custom", "value")
			.add_header("x-empty", "")
			.with_body(Str.to_utf8("payload")),
	))?
	show!("explicit content type", echo!(
		Request.from_method(PATCH)
			.with_uri("${base}/x/echo")
			.add_header("Content-Type", "application/json")
			.with_body(Str.to_utf8("{}")),
	))?
	show!("DELETE echo", echo!(Request.from_method(DELETE).with_uri("${base}/x/echo")))?
	show!("OPTIONS echo", echo!(Request.from_method(OPTIONS).with_uri("${base}/x/echo")))?
	show!("QUERY echo", echo!(Request.from_method(QUERY).with_uri("${base}/x/echo").with_body(Str.to_utf8("q"))))?
	show!("extension method", echo!(Request.from_method(Unknown("PURGE")).with_uri("${base}/x/echo")))?
	show!("invalid method", echo!(Request.from_method(Unknown("BAD METHOD")).with_uri("${base}/x/echo")))?
	show!("invalid header name", echo!(Request.from_method(GET).with_uri("${base}/x/echo").add_header("bad name", "v")))?
	show!("invalid header value", echo!(Request.from_method(GET).with_uri("${base}/x/echo").add_header("x-bad", "a\nb")))?
	show!("large body", echo!(Request.from_method(POST).with_uri("${base}/x/echo").with_body(List.repeat(97, 3000))).map_ok(|body| body.count_utf8_bytes()))?

	show!("HEAD", summary(send!(HEAD, "/x/status/200")))?
	show!("timeout", summary(Http.send!(Request.from_method(GET).with_uri("${base}/x/slow/2000").with_timeout(TimeoutMilliseconds(300)))))?
	show!("within the timeout", summary(Http.send!(Request.from_method(GET).with_uri("${base}/x/slow/50").with_timeout(TimeoutMilliseconds(5000)))))?
	show!("refused", summary(Http.send!(Request.from_method(GET).with_uri("http://127.0.0.1:9001/"))))?
	show!("not UTF-8", Http.get_utf8!("http://127.0.0.1:9000/invalid-utf8"))?
	show!("localhost", Http.get_utf8!("http://localhost:9000/utf8test"))?
	# Enough requests in a loop for LuaJIT to compile the calling code.
	show!("300 requests", repeat!(300, 0))?
	Ok({})
}

repeat! = |n, total|
	if n == 0 {
		Ok(total)
	} else {
		status = Http.send!(Request.from_method(GET).with_uri("${base}/x/status/204")).map_ok(Response.status) ? |e| e
		repeat!(n - 1, total + status.to_u64())
	}
