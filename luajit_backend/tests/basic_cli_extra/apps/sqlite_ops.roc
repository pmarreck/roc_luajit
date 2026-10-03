## Sqlite through basic-cli: every value type in and out, integers past 2^53,
## invalid UTF-8 text (decoded lossily), empty blobs, prepared statements
## reused with fresh bindings, the pinned `:memory:` connection, a file
## database, and the error paths (syntax, unknown parameter, UNIQUE
## violation, rows returned to execute!, a missing column, a path that cannot
## be opened). Printed with Str.inspect for comparison with the native build.
app [main!] { pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.23.0/GNN5tt2gKdX4dhawg4915C4YB193woHFdcCkz31fhGxv.tar.zst" }

import pf.OsStr
import pf.Path
import pf.Sqlite
import pf.Stdout

show! = |label, value| Stdout.line!("${label}: ${Str.inspect(value)}")

row = Sqlite.decode_record(
	Sqlite.decode_record(Sqlite.tagged_value("id"), Sqlite.tagged_value("name"), |id, name| { id, name }),
	Sqlite.decode_record(Sqlite.tagged_value("score"), Sqlite.decode_record(Sqlite.tagged_value("data"), Sqlite.tagged_value("note"), |data, note| { data, note }), |score, rest| { score, data: rest.data, note: rest.note }),
	|a, b| { id: a.id, name: a.name, score: b.score, data: b.data, note: b.note },
)

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	memory = Path.unix(":memory:")
	exec! = |path, query, bindings| Sqlite.execute!({ path, query, bindings })

	show!("create", exec!(memory, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, score REAL, data BLOB, note TEXT);", []))?
	insert = Sqlite.prepare!({ path: memory, query: "INSERT INTO t (id, name, score, data, note) VALUES (:id, :name, :score, :data, :note);" })?
	show!("insert 1", insert.execute!([
		{ name: ":id", value: Integer(1) },
		{ name: ":name", value: String("alpha") },
		{ name: ":score", value: Real(1.5) },
		{ name: ":data", value: Bytes([0, 1, 255]) },
		{ name: ":note", value: Null },
	]))?
	show!("insert 2 (big integer, UTF-8)", insert.execute!([
		{ name: ":id", value: Integer(9007199254740993) },
		{ name: ":name", value: String("béta ✓") },
		{ name: ":score", value: Real(-0.25) },
		{ name: ":data", value: Bytes([]) },
		{ name: ":note", value: String("two") },
	]))?
	show!("insert with a binding missing (cleared, so NULL)", insert.execute!([
		{ name: ":id", value: Integer(3) },
		{ name: ":name", value: String("gamma") },
	]))?
	show!("insert duplicate name", insert.execute!([
		{ name: ":id", value: Integer(4) },
		{ name: ":name", value: String("alpha") },
	]))?
	show!("unknown parameter", insert.execute!([{ name: ":nope", value: Integer(1) }]))?
	show!("invalid UTF-8 text", exec!(memory, "INSERT INTO t (id, name, note) VALUES (5, 'bytes', CAST(x'66ff6f' AS TEXT));", []))?

	show!("rows", Sqlite.query_many!({ path: memory, query: "SELECT * FROM t ORDER BY id;", bindings: [], rows: row }))?
	show!("one row", Sqlite.query!({ path: memory, query: "SELECT * FROM t WHERE id = :id;", bindings: [{ name: ":id", value: Integer(9007199254740993) }], row }))?
	show!("expressions", Sqlite.query!({ path: memory, query: "SELECT 7 / 2 AS id, 'x' || 'y' AS name, 1e300 * 10 AS score, NULL AS data, typeof(1.0) AS note;", bindings: [], row }))?
	show!("missing column", Sqlite.query!({ path: memory, query: "SELECT 1 AS other;", bindings: [], row: Sqlite.tagged_value("id") }))?
	show!("rows to execute!", exec!(memory, "SELECT * FROM t;", []))?
	show!("syntax error", exec!(memory, "SELEC nonsense;", []))?
	show!("missing table", exec!(memory, "SELECT * FROM missing;", []))?

	Path.create_all!(Path.unix("out"))?
	file = Path.unix("out/test.db")
	show!("file create", exec!(file, "CREATE TABLE kv (k TEXT PRIMARY KEY, v INTEGER);", []))?
	show!("file insert", exec!(file, "INSERT INTO kv VALUES ('a', 1), ('b', 2);", []))?
	show!("file sum", Sqlite.query!({ path: file, query: "SELECT sum(v) AS v FROM kv;", bindings: [], row: Sqlite.i64("v") }))?
	show!("open a directory", exec!(Path.unix("out"), "SELECT 1;", []))?
	Ok({})
}
