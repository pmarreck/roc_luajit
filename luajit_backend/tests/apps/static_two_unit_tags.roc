# A union of exactly two unit variants is laid out as a Bool. Constants built
# at compile time reach the LuaJIT backend as static data, and the first
# variant (discriminant 0) must read as false there, as a runtime value does:
# Lua treats the number 0 as true. Found through basic-cli's Url, whose
# scheme [Http, Https] read as Https in compile-time Url literals.
Site : { scheme : [Http, Https], host : Str, secure : Bool }

plain : Site
plain = { scheme: Http, host: "example.com", secure: Bool.False }

tls : Site
tls = { scheme: Https, host: "example.org", secure: Bool.True }

sites : List(Site)
sites = [plain, tls, { scheme: Http, host: "x", secure: Bool.False }]

describe = |site| {
	name = match site.scheme {
		Http => "http"
		Https => "https"
	}
	"${name}://${site.host} secure=${Str.inspect(site.secure)}"
}

main! = |args| {
	k = List.len(args)
	echo!(describe(plain))
	echo!(describe(tls))
	echo!(Str.join_with(sites.map(describe), ", "))
	runtime = if k == 0 { scheme: Http, host: "runtime", secure: Bool.False } else tls
	echo!(describe(runtime))
	Ok({})
}
