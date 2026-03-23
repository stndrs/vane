# plume

[![Package Version](https://img.shields.io/hexpm/v/plume)](https://hex.pm/packages/plume)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/plume/)

A SQLite driver for Gleam on the BEAM. Wraps [esqlite](https://hex.pm/packages/esqlite) and provides typed parameter binding, automatic transactions, and first-class support for `gleam/time` types.

## Installation

```sh
gleam add plume@1
```

## Quick start

```gleam
import gleam/dynamic/decode
import gleam/io
import gleam/list
import plume

pub fn main() {
  let assert Ok(conn) = plume.config(":memory:") |> plume.open

  let assert Ok(_) =
    "CREATE TABLE cats (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, age INTEGER)"
    |> plume.exec(conn)

  let assert Ok(_) =
    plume.query(
      "INSERT INTO cats (name, age) VALUES (?, ?)",
      [plume.Text("Mochi"), plume.Int(3)],
      conn,
    )

  let assert Ok(queried) =
    plume.query("SELECT name, age FROM cats", [], conn)

  let assert Ok(cats) = {
    use row <- list.try_map(queried.rows)
    decode.run(row, {
      use name <- decode.field(0, decode.string)
      use age <- decode.field(1, decode.int)
      decode.success(#(name, age))
    })
  }

  io.debug(cats)
  // [#("Mochi", 3)]

  let assert Ok(_) = plume.close(conn)
}
```

## Connections

Open a connection with `config` and `open`. The database path can be a file path or `":memory:"` for an in-memory database.

```gleam
let assert Ok(conn) = plume.config("my_app.db") |> plume.open
```

Close it when you're done:

```gleam
let assert Ok(Nil) = plume.close(conn)
```

## Queries

`query` executes SQL with parameter binding and returns rows. `exec` executes SQL that doesn't return rows (DDL, INSERT, UPDATE, DELETE) and returns the number of rows changed.

```gleam
// exec returns the number of changed rows
let assert Ok(0) =
  "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
  |> plume.exec(conn)

let assert Ok(1) =
  "INSERT INTO users VALUES (1, 'alice')"
  |> plume.exec(conn)

// query returns a Queried record with count, fields, and rows
let assert Ok(queried) =
  plume.query("SELECT id, name FROM users WHERE id = ?", [plume.Int(1)], conn)

queried.count   // 1
queried.fields  // ["id", "name"]
queried.rows    // [Dynamic]
```

Rows are returned as `Dynamic` values. Decode them with `gleam/dynamic/decode`:

```gleam
let assert Ok(users) = {
  use row <- list.try_map(queried.rows)
  decode.run(row, {
    use id <- decode.field(0, decode.int)
    use name <- decode.field(1, decode.string)
    decode.success(#(id, name))
  })
}
```

## Parameter binding

All parameters are passed as a `List(Value)`. Values are bound by position using `?` placeholders.

| Variant | Gleam type | SQLite type |
|---|---|---|
| `Null` | - | NULL |
| `Bool(Bool)` | `Bool` | INTEGER (0 or 1) |
| `Int(Int)` | `Int` | INTEGER |
| `Float(Float)` | `Float` | REAL |
| `Text(String)` | `String` | TEXT |
| `Bytea(BitArray)` | `BitArray` | BLOB |
| `Date(calendar.Date)` | `gleam/time/calendar.Date` | TEXT (`YYYY-MM-DD`) |
| `Time(calendar.TimeOfDay)` | `gleam/time/calendar.TimeOfDay` | TEXT (`HH:MM:SS[.mmm]`) |
| `Datetime(calendar.Date, calendar.TimeOfDay)` | date + time | TEXT (`YYYY-MM-DD HH:MM:SS[.mmm]`) |
| `Timestamp(timestamp.Timestamp)` | `gleam/time/timestamp.Timestamp` | TEXT (RFC 3339) |
| `Duration(duration.Duration)` | `gleam/time/duration.Duration` | INTEGER (nanoseconds) |

## Transactions

`transaction` wraps a callback in BEGIN/COMMIT and automatically rolls back on error or crash:

```gleam
let assert Ok(result) =
  plume.transaction(conn, fn(tx) {
    let assert Ok(_) =
      "INSERT INTO users VALUES (2, 'bob')"
      |> plume.exec(tx)

    Ok("done")
  })
```

If the callback returns `Error`, the transaction is rolled back and the error is wrapped in `RollbackError`. If the callback crashes, the transaction is still rolled back safely.

## Errors

All fallible operations return `Result(value, PlumeError)`:

- `ConnectionFailed` -- could not open the database
- `ConnectionUnavailable` -- connection was already closed
- `DbError(code, message, detail, offset)` -- SQLite returned an error with a specific error code, message, extended detail, and byte offset into the SQL
- `PlumeError(message)` -- other errors

Use `error_to_string` to format any `PlumeError` for logging:

```gleam
case plume.exec("bad sql", conn) {
  Ok(n) -> io.debug(n)
  Error(err) -> io.println(plume.error_to_string(err))
}
```

## Status

`status` returns global SQLite memory statistics:

```gleam
let info = plume.status()
info.memory_used      // Stats(used: Int, highwater: Int)
info.pagecache_used   // Stats(used: Int, highwater: Int)
info.malloc_count     // Stats(used: Int, highwater: Int)
// ...
```

## Requirements

- Gleam 1.14+
- Erlang/OTP (BEAM target only -- does not compile to JavaScript)
- A C compiler for the SQLite NIF (provided by the `esqlite` dependency)
