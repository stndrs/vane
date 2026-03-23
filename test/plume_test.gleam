import gleam/dynamic
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit
import plume

pub fn main() {
  gleeunit.main()
}

// Constants

const default_date = calendar.Date(1970, calendar.January, 1)

const default_time = calendar.TimeOfDay(0, 0, 0, 0)

// Helpers

fn connect(next: fn(plume.Connection) -> a) -> a {
  let config = plume.config(":memory:")

  let assert Ok(conn) = plume.open(config)

  next(conn)
}

fn insert_user(conn: plume.Connection, name: String) -> Int {
  let sql = "INSERT INTO users (name) VALUES (?) RETURNING id"
  let assert Ok(queried) = plume.query(sql, [plume.Text(name)], conn)

  let assert 1 = queried.count
  let assert ["id"] = queried.fields
  let assert [row] = queried.rows

  let assert Ok(decoded) =
    decode.run(row, {
      use id <- decode.field(0, decode.int)
      decode.success(id)
    })

  decoded
}

// Decoders

fn decode_rows(
  rows: List(dynamic.Dynamic),
  with decoder: Decoder(a),
) -> Result(List(a), List(decode.DecodeError)) {
  use row <- list.try_map(rows)

  decode.run(row, decoder)
}

fn decode_date() -> Decoder(calendar.Date) {
  use date <- decode.then(decode.string)

  let date_parts =
    date
    |> string.split(on: "-")

  case date_parts {
    [year, month, day] -> {
      {
        use year <- result.try(int.parse(year))
        use month <- result.try(int.parse(month))
        use month <- result.try(calendar.month_from_int(month))
        use day <- result.map(int.parse(day))

        calendar.Date(year, month, day)
        |> decode.success
      }
      |> result.lazy_unwrap(fn() {
        decode.failure(calendar.Date(1970, calendar.January, 1), "Date")
      })
    }
    _ -> decode.failure(calendar.Date(1970, calendar.January, 1), "Date")
  }
}

fn decode_duration() -> Decoder(duration.Duration) {
  use dur <- decode.then(decode.int)

  let sec = dur / 1_000_000_000
  let nsec = dur % 1_000_000_000

  duration.seconds(sec)
  |> duration.add(duration.nanoseconds(nsec))
  |> decode.success
}

fn decode_time() -> Decoder(calendar.TimeOfDay) {
  use time <- decode.then(decode.string)

  let time_parts =
    time
    |> string.split(on: ":")

  case time_parts {
    [hours, minutes, seconds] -> {
      {
        use hours <- result.try(int.parse(hours))
        use minutes <- result.try(int.parse(minutes))

        let seconds = string.split(seconds, on: ".")

        let #(seconds, nanoseconds) = case seconds {
          [seconds] -> #(int.parse(seconds), Ok(0))
          [seconds, nanoseconds] -> #(
            int.parse(seconds),
            int.parse(nanoseconds),
          )
          _ -> #(Error(Nil), Error(Nil))
        }

        use seconds <- result.try(seconds)
        use nanoseconds <- result.map(nanoseconds)
        let nanoseconds = nanoseconds * 1_000_000

        calendar.TimeOfDay(hours, minutes, seconds, nanoseconds)
        |> decode.success
      }
      |> result.lazy_unwrap(fn() {
        decode.failure(calendar.TimeOfDay(0, 0, 0, 0), "Time")
      })
    }
    _ -> decode.failure(calendar.TimeOfDay(0, 0, 0, 0), "Time")
  }
}

fn decode_timestamp() -> Decoder(timestamp.Timestamp) {
  use ts <- decode.then(decode.string)

  case timestamp.parse_rfc3339(ts) {
    Ok(ts) -> decode.success(ts)
    Error(_) ->
      timestamp.from_calendar(default_date, default_time, duration.seconds(0))
      |> decode.failure("Timestamp")
  }
}

fn decode_datetime() -> Decoder(#(calendar.Date, calendar.TimeOfDay)) {
  use dt <- decode.then(decode.string)

  let parts = string.split(dt, on: " ")

  case parts {
    [date_str, time_str] -> {
      {
        // Parse date part
        let date_parts = string.split(date_str, on: "-")
        use #(year, month, day) <- result.try(case date_parts {
          [y, m, d] -> {
            use year <- result.try(int.parse(y))
            use month <- result.try(int.parse(m))
            use month <- result.try(calendar.month_from_int(month))
            use day <- result.map(int.parse(d))
            #(year, month, day)
          }
          _ -> Error(Nil)
        })

        // Parse time part
        let time_parts = string.split(time_str, on: ":")
        use #(hours, minutes, seconds, nanoseconds) <- result.map(
          case time_parts {
            [h, m, s] -> {
              use hours <- result.try(int.parse(h))
              use minutes <- result.try(int.parse(m))

              let sec_parts = string.split(s, on: ".")
              let #(seconds, nanoseconds) = case sec_parts {
                [sec] -> #(int.parse(sec), Ok(0))
                [sec, ms] -> #(
                  int.parse(sec),
                  int.parse(ms) |> result.map(fn(n) { n * 1_000_000 }),
                )
                _ -> #(Error(Nil), Error(Nil))
              }

              use seconds <- result.try(seconds)
              use nanoseconds <- result.map(nanoseconds)
              #(hours, minutes, seconds, nanoseconds)
            }
            _ -> Error(Nil)
          },
        )

        let date = calendar.Date(year, month, day)
        let time = calendar.TimeOfDay(hours, minutes, seconds, nanoseconds)
        #(date, time) |> decode.success
      }
      |> result.lazy_unwrap(fn() {
        decode.failure(#(default_date, default_time), "Datetime")
      })
    }
    _ -> decode.failure(#(default_date, default_time), "Datetime")
  }
}

// Tests

pub fn config_test() {
  let conf = plume.config(":memory:")

  assert conf.db == ":memory:"
}

// Status tests

pub fn status_test() {
  let assert plume.StatusInfo(
    memory_used: plume.Stats(used: 0, highwater: 0),
    pagecache_used: plume.Stats(used: 0, highwater: 0),
    pagecache_overflow: plume.Stats(used: 0, highwater: 0),
    malloc_size: plume.Stats(used: 0, highwater: 0),
    parser_stack: plume.Stats(used: 0, highwater: 0),
    pagecache_size: plume.Stats(used: 0, highwater: 0),
    malloc_count: plume.Stats(used: 0, highwater: 0),
  ) = plume.status()
}

pub fn execute_test() {
  use conn <- connect()

  let assert Ok(_) =
    "create table users (id INTEGER NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL);"
    |> plume.exec(conn)

  let assert Ok(1) =
    "insert into users (id, name, email) values (1, 'glia', 'glia@glia.dev')"
    |> plume.exec(conn)

  let assert Ok(1) =
    "insert into users (id, name, email) values (2, 'todd', 'todd@glia.dev')"
    |> plume.exec(conn)

  let assert Ok(queried) =
    "SELECT email, id FROM users;"
    |> plume.query([], conn)

  let assert 2 = queried.count
  let assert ["email", "id"] = queried.fields
  let rows = [
    dynamic.array([dynamic.string("glia@glia.dev"), dynamic.int(1)]),
    dynamic.array([dynamic.string("todd@glia.dev"), dynamic.int(2)]),
  ]
  assert rows == queried.rows
}

pub fn query_test() {
  use conn <- connect()
  let assert Ok(_) = plume.exec("create table users (name text)", conn)

  let assert Ok(1) = plume.exec("insert into users (name) values ('Tim')", conn)

  let assert Ok(queried) =
    "select name from users"
    |> plume.query([], conn)

  let assert 1 = queried.count
}

pub fn transaction_commit_test() {
  use conn <- connect()

  let assert Ok(_) =
    plume.exec(
      "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
      conn,
    )

  let assert Ok(#(1, 2)) =
    plume.transaction(conn, fn(tx) {
      let id1 = insert_user(tx, "'Tim'")
      let id2 = insert_user(tx, "'Tom'")
      Ok(#(id1, id2))
    })

  let assert Ok(queried) = plume.query("SELECT id FROM users", [], conn)

  let assert 2 = queried.count
}

pub fn transaction_error_rollback_test() {
  use conn <- connect()

  let assert Ok(_) =
    plume.exec(
      "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
      conn,
    )

  let assert Error(plume.RollbackError("Intentional error")) =
    plume.transaction(conn, fn(tx) {
      let _id1 = insert_user(tx, "'Tim'")
      let _id2 = insert_user(tx, "'Tom'")
      Error("Intentional error")
    })

  let assert Ok(queried) = plume.query("SELECT COUNT(*) FROM users", [], conn)

  let assert 1 = queried.count
}

pub fn transaction_panic_rollback_test() {
  use conn <- connect()

  let assert Ok(_) =
    plume.exec(
      "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
      conn,
    )

  let _ =
    with_rescue(fn() {
      plume.transaction(conn, fn(tx) {
        let _id1 = insert_user(tx, "'Tim'")
        let _id2 = insert_user(tx, "'Tom'")
        panic as "Intentional panic"
      })
    })

  let assert Ok(queried) = plume.query("SELECT COUNT(*) FROM users", [], conn)

  let assert 1 = queried.count
}

pub fn syntax_error_test() {
  use conn <- connect()

  let assert Error(plume.DbError(code, msg, detail, offset)) =
    "SELEKT * FROM non_existent_table"
    |> plume.exec(conn)

  assert plume.GenericError == code
  assert "near \"SELEKT\": syntax error" == msg
  assert "SQL logic error" == detail
  assert offset >= 0
}

pub fn constraint_error_primary_key_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)"
    |> plume.exec(conn)

  let assert Ok(1) =
    "INSERT INTO users (id, name) VALUES (1, 'First User')"
    |> plume.exec(conn)

  let assert Error(plume.DbError(code, msg, detail, _offset)) =
    "INSERT INTO users (id, name) VALUES (1, 'Duplicate User')"
    |> plume.exec(conn)

  assert plume.ConstraintPrimarykey == code
  assert "UNIQUE constraint failed: users.id" == msg
  assert "constraint failed" == detail
}

pub fn constraint_error_not_null_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE required (id INTEGER, name TEXT NOT NULL)"
    |> plume.exec(conn)

  let assert Error(plume.DbError(code, msg, detail, _offset)) =
    "INSERT INTO required (id) VALUES (1)"
    |> plume.exec(conn)

  assert plume.ConstraintNotnull == code
  assert "NOT NULL constraint failed: required.name" == msg
  assert "constraint failed" == detail
}

pub fn transaction_rollback_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE tx_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> plume.exec(conn)

  let assert Ok(_) =
    "INSERT INTO tx_test (id, name) VALUES (1, 'Before')"
    |> plume.exec(conn)

  let assert Error(plume.RollbackError(msg)) =
    plume.transaction(conn, fn(tx) {
      let assert Ok(_) =
        "INSERT INTO tx_test (id, name) VALUES (2, 'Transaction')"
        |> plume.exec(tx)

      let error =
        "INSERT INTO tx_test (id, name) VALUES (1, 'Duplicate')"
        |> plume.exec(tx)

      case error {
        Error(_) -> Error("Expected error")
        Ok(_) -> Ok("This shouldn't happen")
      }
    })

  assert "Expected error" == msg

  let assert Ok(queried) =
    "SELECT COUNT(*) FROM tx_test"
    |> plume.query([], conn)

  let assert Ok([1]) =
    decode_rows(queried.rows, {
      use count <- decode.field(0, decode.int)
      decode.success(count)
    })
}

pub fn table_not_exist_error_test() {
  use conn <- connect()

  let assert Error(plume.DbError(code, msg, detail, _offset)) =
    "SELECT * FROM non_existent_table"
    |> plume.query([], conn)

  assert plume.GenericError == code
  assert msg == "no such table: non_existent_table"
  assert detail == "SQL logic error"
}

// Date tests

pub fn date_bind_test() {
  use conn <- connect()

  let date = calendar.Date(year: 2025, month: calendar.April, day: 19)
  let assert Ok(queried) = plume.query("SELECT ?", [plume.Date(date)], conn)

  assert 1 == queried.count
}

pub fn date_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE date_test (id INTEGER PRIMARY KEY AUTOINCREMENT, date_col TEXT)"
    |> plume.exec(conn)

  let dates = [
    calendar.Date(year: 2025, month: calendar.April, day: 19),
    calendar.Date(year: 2000, month: calendar.January, day: 1),
    calendar.Date(year: 1999, month: calendar.December, day: 31),
    calendar.Date(year: 1970, month: calendar.January, day: 1),
    calendar.Date(year: 2038, month: calendar.January, day: 19),
  ]

  let assert Ok(_) = {
    use date <- list.try_map(dates)
    "INSERT INTO date_test (date_col) VALUES (?) RETURNING *"
    |> plume.query([plume.Date(date)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT date_col FROM date_test ORDER BY id", [], conn)

  let assert 5 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, with: {
      use date_val <- decode.field(0, decode_date())
      decode.success(date_val)
    })

  assert dates == decoded
}

// Duration tests

pub fn duration_bind_test() {
  use conn <- connect()

  let dur = duration.seconds(3600)
  let assert Ok(queried) = plume.query("SELECT ?", [plume.Duration(dur)], conn)

  let assert 1 = queried.count
}

pub fn duration_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE duration_test (id INTEGER PRIMARY KEY AUTOINCREMENT, dur_col INTEGER)"
    |> plume.exec(conn)

  let durations = [
    // 1 minute
    duration.seconds(60),
    // 1 minute, 10.5 seconds
    duration.minutes(1)
      |> duration.add(duration.seconds(10))
      |> duration.add(duration.nanoseconds(500_000_000)),
    // 1 hour
    duration.seconds(3600),
    // 1 day
    duration.seconds(86_400),
    // 1 week
    duration.seconds(604_800),
    // 30 days (approx. 1 month)
    duration.seconds(2_592_000),
  ]

  let assert Ok(_) = {
    use dur <- list.try_map(durations)
    let insert_sql =
      "INSERT INTO duration_test (dur_col) VALUES (?) RETURNING *"

    plume.query(insert_sql, [plume.Duration(dur)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT dur_col FROM duration_test ORDER BY id", [], conn)

  let assert 6 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, with: {
      use dur <- decode.field(0, decode_duration())
      decode.success(dur)
    })

  assert durations == decoded
}

// Time tests

pub fn time_bind_test() {
  use conn <- connect()

  let time =
    calendar.TimeOfDay(
      hours: 14,
      minutes: 30,
      seconds: 45,
      nanoseconds: 123_456_789,
    )

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Time(time)], conn)

  let assert 1 = queried.count
}

pub fn time_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE time_test (id INTEGER PRIMARY KEY AUTOINCREMENT, time_col INTEGER)"
    |> plume.exec(conn)

  let times = [
    // Midnight
    calendar.TimeOfDay(0, 0, 0, 0),
    // Just before midnight
    calendar.TimeOfDay(23, 59, 59, 999_000_000),
    // Noon-ish
    calendar.TimeOfDay(12, 30, 45, 500_000_000),
    // Morning
    calendar.TimeOfDay(8, 15, 0, 0),
    // Evening
    calendar.TimeOfDay(18, 45, 30, 250_000_000),
  ]

  let assert Ok(_) = {
    use time <- list.try_map(times)
    let insert_sql = "INSERT INTO time_test (time_col) VALUES (?) RETURNING *"

    plume.query(insert_sql, [plume.Time(time)], conn)
  }

  let sql = "SELECT time_col FROM time_test ORDER BY id"

  let assert Ok(queried) = plume.query(sql, [], conn)

  let assert 5 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, with: {
      use time <- decode.field(0, decode_time())
      decode.success(time)
    })

  assert times == decoded
}

// Timestamp tests

pub fn timestamp_bind_test() {
  use conn <- connect()

  // 2025-04-19 20:30:00 UTC
  let ts = timestamp.from_unix_seconds(1_713_557_400)

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Timestamp(ts)], conn)

  let assert 1 = queried.count
}

pub fn timestamp_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE timestamp_test (id INTEGER PRIMARY KEY AUTOINCREMENT, ts_col TIMESTAMP)"
    |> plume.exec(conn)

  let timestamps = [
    // 2025-04-19 20:30:00 UTC
    timestamp.from_unix_seconds(1_713_557_400),
    // 2000-01-01 00:00:00 UTC (Millennium)
    timestamp.from_unix_seconds(946_684_800),
    // 2022-01-01 00:00:00 UTC
    timestamp.from_unix_seconds(1_640_995_200),
    // 1970-01-01 00:00:00 UTC (Unix epoch)
    timestamp.from_unix_seconds(0),
    // 2038-01-19 03:14:07 UTC (Unix time max)
    timestamp.from_unix_seconds(2_147_483_647),
    // 2025-04-19 20:30:00.250000 UTC
    timestamp.from_unix_seconds_and_nanoseconds(1_713_557_400, 250_000_000),
  ]

  let assert Ok(_) = {
    use ts <- list.try_map(timestamps)

    "INSERT INTO timestamp_test (ts_col) VALUES (?) RETURNING *"
    |> plume.query([plume.Timestamp(ts)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT ts_col FROM timestamp_test ORDER BY id", [], conn)

  let assert 6 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, with: {
      use ts <- decode.field(0, decode_timestamp())
      decode.success(ts)
    })

  assert timestamps == decoded
}

// Null tests

pub fn null_bind_test() {
  use conn <- connect()

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Null], conn)

  let assert 1 = queried.count

  let assert Ok([None]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.optional(decode.string))
      decode.success(val)
    })
}

pub fn null_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE null_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)"
    |> plume.exec(conn)

  let assert Ok(_) =
    "INSERT INTO null_test (val) VALUES (?)"
    |> plume.query([plume.Null], conn)

  let assert Ok(_) =
    "INSERT INTO null_test (val) VALUES (?)"
    |> plume.query([plume.Text("not null")], conn)

  let assert Ok(queried) =
    plume.query("SELECT val FROM null_test ORDER BY id", [], conn)

  let assert 2 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.optional(decode.string))
      decode.success(val)
    })

  assert decoded == [None, Some("not null")]
}

// Bool tests

pub fn bool_bind_test() {
  use conn <- connect()

  let assert Ok(queried) =
    plume.query("SELECT ?, ?", [plume.Bool(True), plume.Bool(False)], conn)

  let assert 1 = queried.count

  let assert Ok([#(1, 0)]) =
    decode_rows(queried.rows, {
      use a <- decode.field(0, decode.int)
      use b <- decode.field(1, decode.int)
      decode.success(#(a, b))
    })
}

pub fn bool_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE bool_test (id INTEGER PRIMARY KEY AUTOINCREMENT, flag INTEGER)"
    |> plume.exec(conn)

  let values = [True, False, True, False]

  let assert Ok(_) = {
    use val <- list.try_map(values)
    "INSERT INTO bool_test (flag) VALUES (?)"
    |> plume.query([plume.Bool(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT flag FROM bool_test ORDER BY id", [], conn)

  let assert 4 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use flag <- decode.field(0, decode.int)
      decode.success(flag)
    })

  // Bool(True) stores as 1, Bool(False) stores as 0
  assert decoded == [1, 0, 1, 0]
}

// Float tests

pub fn float_bind_test() {
  use conn <- connect()

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Float(3.14)], conn)

  let assert 1 = queried.count

  let assert Ok([3.14]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.float)
      decode.success(val)
    })
}

pub fn float_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE float_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val REAL)"
    |> plume.exec(conn)

  let floats = [0.0, 1.5, -42.195, 3.14159265358979, 1.0e10]

  let assert Ok(_) = {
    use val <- list.try_map(floats)
    "INSERT INTO float_test (val) VALUES (?)"
    |> plume.query([plume.Float(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT val FROM float_test ORDER BY id", [], conn)

  let assert 5 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.float)
      decode.success(val)
    })

  assert floats == decoded
}

// Bytea tests

pub fn bytea_bind_test() {
  use conn <- connect()

  let bytes = <<0, 1, 2, 255>>
  let assert Ok(queried) = plume.query("SELECT ?", [plume.Bytea(bytes)], conn)

  let assert 1 = queried.count

  let assert Ok([<<0, 1, 2, 255>>]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.bit_array)
      decode.success(val)
    })
}

pub fn bytea_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE bytea_test (id INTEGER PRIMARY KEY AUTOINCREMENT, data BLOB)"
    |> plume.exec(conn)

  let blobs = [
    <<>>,
    <<0>>,
    <<0, 1, 2, 3, 4, 5>>,
    <<255, 254, 253>>,
    <<"hello world":utf8>>,
  ]

  let assert Ok(_) = {
    use val <- list.try_map(blobs)
    "INSERT INTO bytea_test (data) VALUES (?)"
    |> plume.query([plume.Bytea(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT data FROM bytea_test ORDER BY id", [], conn)

  let assert 5 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.bit_array)
      decode.success(val)
    })

  assert blobs == decoded
}

// Datetime tests

pub fn datetime_bind_test() {
  use conn <- connect()

  let date = calendar.Date(year: 2025, month: calendar.April, day: 19)
  let time =
    calendar.TimeOfDay(hours: 14, minutes: 30, seconds: 45, nanoseconds: 0)

  let assert Ok(queried) =
    plume.query("SELECT ?", [plume.Datetime(date, time)], conn)

  let assert 1 = queried.count
}

pub fn datetime_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE datetime_test (id INTEGER PRIMARY KEY AUTOINCREMENT, dt_col TEXT)"
    |> plume.exec(conn)

  let datetimes = [
    // Simple date + time
    #(
      calendar.Date(2025, calendar.April, 19),
      calendar.TimeOfDay(14, 30, 45, 0),
    ),
    // Midnight on Y2K
    #(calendar.Date(2000, calendar.January, 1), calendar.TimeOfDay(0, 0, 0, 0)),
    // Just before midnight on NYE
    #(
      calendar.Date(1999, calendar.December, 31),
      calendar.TimeOfDay(23, 59, 59, 999_000_000),
    ),
    // With milliseconds
    #(
      calendar.Date(2038, calendar.January, 19),
      calendar.TimeOfDay(3, 14, 7, 500_000_000),
    ),
  ]

  let assert Ok(_) = {
    use dt <- list.try_map(datetimes)
    let #(date, time) = dt
    "INSERT INTO datetime_test (dt_col) VALUES (?)"
    |> plume.query([plume.Datetime(date, time)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT dt_col FROM datetime_test ORDER BY id", [], conn)

  let assert 4 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, with: {
      use dt <- decode.field(0, decode_datetime())
      decode.success(dt)
    })

  assert datetimes == decoded
}

// Empty result set test

pub fn empty_result_set_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE empty_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> plume.exec(conn)

  let assert Ok(queried) =
    plume.query("SELECT id, name FROM empty_test", [], conn)

  assert queried.count == 0
  assert queried.rows == []
  assert queried.fields == ["id", "name"]
}

// Multiple mixed parameters test

pub fn multiple_mixed_params_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE mixed_test (id INTEGER, name TEXT, score REAL, data BLOB, active INTEGER)"
    |> plume.exec(conn)

  let assert Ok(_) =
    "INSERT INTO mixed_test (id, name, score, data, active) VALUES (?, ?, ?, ?, ?)"
    |> plume.query(
      [
        plume.Int(42),
        plume.Text("Alice"),
        plume.Float(99.5),
        plume.Bytea(<<1, 2, 3>>),
        plume.Bool(True),
      ],
      conn,
    )

  let assert Ok(_) =
    "INSERT INTO mixed_test (id, name, score, data, active) VALUES (?, ?, ?, ?, ?)"
    |> plume.query(
      [
        plume.Int(43),
        plume.Null,
        plume.Float(0.0),
        plume.Bytea(<<>>),
        plume.Bool(False),
      ],
      conn,
    )

  let assert Ok(queried) =
    plume.query(
      "SELECT id, name, score, data, active FROM mixed_test ORDER BY id",
      [],
      conn,
    )

  let assert 2 = queried.count
  let assert ["id", "name", "score", "data", "active"] = queried.fields

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use id <- decode.field(0, decode.int)
      use name <- decode.field(1, decode.optional(decode.string))
      use score <- decode.field(2, decode.float)
      use data <- decode.field(3, decode.bit_array)
      use active <- decode.field(4, decode.int)
      decode.success(#(id, name, score, data, active))
    })

  assert decoded
    == [
      #(42, Some("Alice"), 99.5, <<1, 2, 3>>, 1),
      #(43, None, 0.0, <<>>, 0),
    ]
}

// Empty string test

pub fn empty_string_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE string_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)"
    |> plume.exec(conn)

  let assert Ok(_) =
    "INSERT INTO string_test (val) VALUES (?)"
    |> plume.query([plume.Text("")], conn)

  let assert Ok(queried) = plume.query("SELECT val FROM string_test", [], conn)

  let assert 1 = queried.count

  let assert Ok([""]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })
}

// error_to_string test

pub fn error_to_string_test() {
  use conn <- connect()

  let assert Error(err) =
    "SELEKT * FROM nope"
    |> plume.exec(conn)

  let msg = plume.error_to_string(err)

  assert string.contains(msg, "ERROR")
  assert string.contains(msg, "SELEKT")
}

// Use-after-close test

pub fn use_after_close_crashes_test() {
  let config = plume.config(":memory:")
  let assert Ok(conn) = plume.open(config)
  let assert Ok(Nil) = plume.close(conn)

  // exec on a closed connection triggers handle_conn_error -> code_to_error
  // which calls esqplume3_nif:error_info on the closed ref and crashes

  let result = plume.exec("SELECT 1", conn)
  let assert Error(_crash) = result
}

// pub fn close_after_close_test() {
//   todo
// }

@external(erlang, "plume_ffi", "rescue")
fn with_rescue(next: fn() -> t) -> Result(t, Nil)
