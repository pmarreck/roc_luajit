import Host

## Run Lua code from Roc, on LuaJIT, whichever way the program is built.
##
## ```roc
## doubled = Lua.eval!("return ... * 2", [Int(21)])?
## # doubled == Int(42)
## ```
##
## Every eval in a run shares one Lua environment: globals a snippet defines
## stay defined for later evals (the standard globals show through), apart
## from the Roc program's own state.
Lua :: [].{

	## A Lua value. Lua has one number type, so an integral number within
	## +-2^53 comes back from Lua as `Int` even when it was sent as `Num`.
	## Tables are their key/value pairs, keys sorted by type (Bool, then
	## numbers, then Str) and then value; pairs whose value is `Nil` do not
	## exist in Lua and are dropped.
	Value := [Nil, Bool(Bool), Int(I64), Num(F64), Str(Str), Table(List((Value, Value)))]

	## Errors from `eval!`: the code did not compile, or it raised an error
	## (including returning a value Roc cannot represent, such as a function).
	Error : [LuaSyntax(Str), LuaRuntime(Str)]

	## Run `code` with `args` as its `...`, returning its first result.
	eval! : Str, List(Value) => Try(Value, Error)
	eval! = |code, args| {
		response = call!("eval", [Str(code)].concat(args))
		when_ok(response, |v| Ok(v), |fields| {
			msg = field_str(fields, "msg")
			if field_str(fields, "err") == "syntax" Err(LuaSyntax(msg)) else Err(LuaRuntime(msg))
		})
	}

	## Call a platform op with arguments, returning the response's fields.
	## A response that does not decode is a host bug, so it crashes.
	call! : Str, List(Value) => List((Value, Value))
	call! = |op, args| {
		request = encode(Table(args.map_with_index(|v, i| (Int(i.to_i64_wrap() + 1), v))))
		match decode(Host.call!(op, request)) {
			Ok(Table(fields)) => fields
			_ => crash "the Lua platform host answered ${op} with malformed bytes"
		}
	}

	## On success (`ok` is true) `on_ok` of the response's value (`Nil` when
	## it has none), else `on_err` of its fields.
	when_ok : List((Value, Value)), (Value -> a), (List((Value, Value)) -> a) -> a
	when_ok = |fields, on_ok, on_err|
		if field_true(fields, "ok") {
			match field(fields, "value") {
				Ok(v) => on_ok(v)
				Err(_) => on_ok(Nil)
			}
		} else {
			on_err(fields)
		}

	field : List((Value, Value)), Str -> Try(Value, [Missing])
	field = |fields, name| {
		var $found = Err(Missing)
		for (k, v) in fields {
			match k {
				Str(key) => if key == name {
					$found = Ok(v)
				}
				_ => {}
			}
		}
		$found
	}

	## Whether the response field `name` is `Bool(True)`.
	field_true : List((Value, Value)), Str -> Bool
	field_true = |fields, name|
		match field(fields, name) {
			Ok(Bool(True)) => True
			_ => False
		}

	field_str : List((Value, Value)), Str -> Str
	field_str = |fields, name|
		match field(fields, name) {
			Ok(Str(s)) => s
			_ => ""
		}

	## Encode a value as LuaValue bytes (the platform's host codec).
	encode : Value -> List(U8)
	encode = |value| encode_into([], value)

	encode_into : List(U8), Value -> List(U8)
	encode_into = |bytes, value|
		match value {
			Nil => bytes.append(0)
			Bool(b) => bytes.append(if b 2 else 1)
			Int(n) => le(bytes.append(3), n.to_u64_wrap(), 8)
			Num(x) => le(bytes.append(4), x.to_bits(), 8)
			Str(s) => {
				utf8 = s.to_utf8()
				le(bytes.append(5), utf8.len(), 4).concat(utf8)
			}
			Table(pairs) => {
				var $out = le(bytes.append(6), pairs.len(), 4)
				for (k, v) in pairs {
					$out = encode_into(encode_into($out, k), v)
				}
				$out
			}
		}

	le : List(U8), U64, U8 -> List(U8)
	le = |bytes, n, count|
		match n.append_le_bytes_to(bytes, count) {
			Ok(out) => out
			Err(_) => crash "a LuaValue length does not fit its field"
		}

	## Decode LuaValue bytes; `Malformed` for anything but exactly one value.
	decode : List(U8) -> Try(Value, [Malformed])
	decode = |bytes|
		match decode_at(bytes, 0) {
			Ok((value, next)) => if next == bytes.len() Ok(value) else Err(Malformed)
			Err(_) => Err(Malformed)
		}

	decode_at : List(U8), U64 -> Try((Value, U64), [Malformed])
	decode_at = |bytes, at|
		match bytes.get(at) {
			Ok(0) => Ok((Nil, at + 1))
			Ok(1) => Ok((Bool(False), at + 1))
			Ok(2) => Ok((Bool(True), at + 1))
			Ok(3) => match U64.from_le_bytes(bytes, at + 1) {
				Ok(n) => Ok((Int(n.to_i64_wrap()), at + 9))
				Err(_) => Err(Malformed)
			}
			Ok(4) => match U64.from_le_bytes(bytes, at + 1) {
				Ok(n) => Ok((Num(F64.from_bits(n)), at + 9))
				Err(_) => Err(Malformed)
			}
			Ok(5) => match U32.from_le_bytes(bytes, at + 1) {
				Ok(len) => {
					start = at + 5
					end = start + len.to_u64()
					if end > bytes.len() {
						Err(Malformed)
					} else {
						match Str.from_utf8(bytes.sublist({ start, len: len.to_u64() })) {
							Ok(s) => Ok((Str(s), end))
							Err(_) => Err(Malformed)
						}
					}
				}
				Err(_) => Err(Malformed)
			}
			Ok(6) => match U32.from_le_bytes(bytes, at + 1) {
				Ok(count) => {
					var $pairs = List.with_capacity(count.to_u64())
					var $next = at + 5
					var $ok = True
					var $i = 0
					while $ok and $i < count {
						match decode_at(bytes, $next) {
							Ok((k, after_k)) => match decode_at(bytes, after_k) {
								Ok((v, after_v)) => {
									$pairs = $pairs.append((k, v))
									$next = after_v
								}
								Err(_) => {
									$ok = False
								}
							}
							Err(_) => {
								$ok = False
							}
						}
						$i = $i + 1
					}
					if $ok Ok((Table($pairs), $next)) else Err(Malformed)
				}
				Err(_) => Err(Malformed)
			}
			_ => Err(Malformed)
		}
}
