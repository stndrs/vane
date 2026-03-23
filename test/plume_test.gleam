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

pub fn use_after_close_crashes_test() {
  let config = plume.config(":memory:")
  let assert Ok(conn) = plume.open(config)
  let assert Ok(Nil) = plume.close(conn)

  let result = plume.exec("SELECT 1", conn)
  let assert Error(plume.ConnectionUnavailable) = result
}

pub fn open_invalid_path_test() {
  let config = plume.config("/nonexistent/path/to/db.sqlite")
  let assert Error(plume.ConnectionFailed) = plume.open(config)
}

pub fn close_double_close_test() {
  let config = plume.config(":memory:")
  let assert Ok(conn) = plume.open(config)
  let assert Ok(Nil) = plume.close(conn)

  let _result = plume.close(conn)
}

pub fn use_after_close_returns_connection_unavailable_test() {
  let config = plume.config(":memory:")
  let assert Ok(conn) = plume.open(config)
  let assert Ok(Nil) = plume.close(conn)

  let assert Error(plume.ConnectionUnavailable) = plume.exec("SELECT 1", conn)
}

pub fn query_after_close_returns_connection_unavailable_test() {
  let config = plume.config(":memory:")
  let assert Ok(conn) = plume.open(config)
  let assert Ok(Nil) = plume.close(conn)

  let assert Error(plume.ConnectionUnavailable) =
    plume.query("SELECT 1", [], conn)
}

pub fn int_bind_test() {
  use conn <- connect()

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Int(42)], conn)

  let assert 1 = queried.count

  let assert Ok([42]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.int)
      decode.success(val)
    })
}

pub fn int_roundtrip_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE int_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val INTEGER)"
    |> plume.exec(conn)

  let ints = [0, 1, -1, 42, -42, 2_147_483_647, -2_147_483_648]

  let assert Ok(_) = {
    use val <- list.try_map(ints)
    "INSERT INTO int_test (val) VALUES (?)"
    |> plume.query([plume.Int(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT val FROM int_test ORDER BY id", [], conn)

  let assert 7 = queried.count

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.int)
      decode.success(val)
    })

  assert ints == decoded
}

pub fn int_large_values_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE bigint_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val INTEGER)"
    |> plume.exec(conn)

  let large_ints = [
    9_223_372_036_854_775_807,
    -9_223_372_036_854_775_807,
  ]

  let assert Ok(_) = {
    use val <- list.try_map(large_ints)
    "INSERT INTO bigint_test (val) VALUES (?)"
    |> plume.query([plume.Int(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT val FROM bigint_test ORDER BY id", [], conn)

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.int)
      decode.success(val)
    })

  assert large_ints == decoded
}

pub fn text_bind_test() {
  use conn <- connect()

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Text("hello")], conn)

  let assert 1 = queried.count

  let assert Ok(["hello"]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })
}

pub fn text_unicode_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE unicode_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)"
    |> plume.exec(conn)

  let strings = [
    "Hello 🌍🎉",
    "你好世界",
    "مرحبا",
    "e\u{0301}",
    "café ☕ naïve 日本語",
  ]

  let assert Ok(_) = {
    use val <- list.try_map(strings)
    "INSERT INTO unicode_test (val) VALUES (?)"
    |> plume.query([plume.Text(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT val FROM unicode_test ORDER BY id", [], conn)

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })

  assert strings == decoded
}

pub fn text_special_chars_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE special_test (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)"
    |> plume.exec(conn)

  let strings = [
    "'; DROP TABLE users; --",
    "line1\nline2\ttab",
    "back\\slash",
    "it's a \"test\"",
  ]

  let assert Ok(_) = {
    use val <- list.try_map(strings)
    "INSERT INTO special_test (val) VALUES (?)"
    |> plume.query([plume.Text(val)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT val FROM special_test ORDER BY id", [], conn)

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })

  assert strings == decoded
}

pub fn error_to_string_connection_failed_test() {
  let msg = plume.error_to_string(plume.ConnectionFailed)
  assert msg == "[plume.ConnectionFailed]"
}

pub fn error_to_string_connection_unavailable_test() {
  let msg = plume.error_to_string(plume.ConnectionUnavailable)
  assert msg == "[plume.ConnectionUnavailable]"
}

pub fn error_to_string_plume_error_test() {
  let msg = plume.error_to_string(plume.PlumeError("something went wrong"))
  assert msg == "[plume.PlumeError] message: something went wrong"
}

pub fn error_to_string_db_error_format_test() {
  let err =
    plume.DbError(
      code: plume.ConstraintUnique,
      message: "UNIQUE constraint failed",
      detail: "constraint failed",
      offset: 42,
    )
  let msg = plume.error_to_string(err)

  assert msg
    == "[plume.DbError] code: CONSTRAINT_UNIQUE, message: UNIQUE constraint failed, detail: constraint failed"
}

pub fn code_from_int_primary_codes_test() {
  assert plume.code_from_int(0) == plume.GenericOk
  assert plume.code_from_int(1) == plume.GenericError
  assert plume.code_from_int(2) == plume.Internal
  assert plume.code_from_int(3) == plume.Perm
  assert plume.code_from_int(4) == plume.Abort
  assert plume.code_from_int(5) == plume.Busy
  assert plume.code_from_int(6) == plume.Locked
  assert plume.code_from_int(7) == plume.Nomem
  assert plume.code_from_int(8) == plume.Readonly
  assert plume.code_from_int(9) == plume.Interrupt
  assert plume.code_from_int(10) == plume.Ioerr
  assert plume.code_from_int(11) == plume.Corrupt
  assert plume.code_from_int(12) == plume.Notfound
  assert plume.code_from_int(13) == plume.Full
  assert plume.code_from_int(14) == plume.Cantopen
  assert plume.code_from_int(15) == plume.Protocol
  assert plume.code_from_int(16) == plume.Empty
  assert plume.code_from_int(17) == plume.Schema
  assert plume.code_from_int(18) == plume.Toobig
  assert plume.code_from_int(19) == plume.Constraint
  assert plume.code_from_int(20) == plume.Mismatch
  assert plume.code_from_int(21) == plume.Misuse
  assert plume.code_from_int(22) == plume.Nolfs
  assert plume.code_from_int(23) == plume.Auth
  assert plume.code_from_int(24) == plume.Format
  assert plume.code_from_int(25) == plume.Range
  assert plume.code_from_int(26) == plume.Notadb
  assert plume.code_from_int(27) == plume.Notice
  assert plume.code_from_int(28) == plume.Warning
  assert plume.code_from_int(100) == plume.Row
  assert plume.code_from_int(101) == plume.Done
}

pub fn code_from_int_extended_codes_test() {
  assert plume.code_from_int(516) == plume.AbortRollback
  assert plume.code_from_int(279) == plume.AuthUser
  assert plume.code_from_int(261) == plume.BusyRecovery
  assert plume.code_from_int(517) == plume.BusySnapshot
  assert plume.code_from_int(773) == plume.BusyTimeout
  assert plume.code_from_int(1038) == plume.CantopenConvpath
  assert plume.code_from_int(1294) == plume.CantopenDirtywal
  assert plume.code_from_int(782) == plume.CantopenFullpath
  assert plume.code_from_int(526) == plume.CantopenIsdir
  assert plume.code_from_int(270) == plume.CantopenNotempdir
  assert plume.code_from_int(1550) == plume.CantopenSymlink
  assert plume.code_from_int(275) == plume.ConstraintCheck
  assert plume.code_from_int(531) == plume.ConstraintCommithook
  assert plume.code_from_int(3091) == plume.ConstraintDatatype
  assert plume.code_from_int(787) == plume.ConstraintForeignkey
  assert plume.code_from_int(1043) == plume.ConstraintFunction
  assert plume.code_from_int(1299) == plume.ConstraintNotnull
  assert plume.code_from_int(2835) == plume.ConstraintPinned
  assert plume.code_from_int(1555) == plume.ConstraintPrimarykey
  assert plume.code_from_int(2579) == plume.ConstraintRowid
  assert plume.code_from_int(1811) == plume.ConstraintTrigger
  assert plume.code_from_int(2067) == plume.ConstraintUnique
  assert plume.code_from_int(2323) == plume.ConstraintVtab
  assert plume.code_from_int(779) == plume.CorruptIndex
  assert plume.code_from_int(523) == plume.CorruptSequence
  assert plume.code_from_int(267) == plume.CorruptVtab
  assert plume.code_from_int(257) == plume.ErrorMissingCollseq
  assert plume.code_from_int(513) == plume.ErrorRetry
  assert plume.code_from_int(769) == plume.ErrorSnapshot
  assert plume.code_from_int(3338) == plume.IoerrAccess
  assert plume.code_from_int(7178) == plume.IoerrAuth
  assert plume.code_from_int(7434) == plume.IoerrBeginAtomic
  assert plume.code_from_int(2826) == plume.IoerrBlocked
  assert plume.code_from_int(3594) == plume.IoerrCheckreservedlock
  assert plume.code_from_int(4106) == plume.IoerrClose
  assert plume.code_from_int(7690) == plume.IoerrCommitAtomic
  assert plume.code_from_int(6666) == plume.IoerrConvpath
  assert plume.code_from_int(8458) == plume.IoerrCorruptfs
  assert plume.code_from_int(8202) == plume.IoerrData
  assert plume.code_from_int(2570) == plume.IoerrDelete
  assert plume.code_from_int(5898) == plume.IoerrDeleteNoent
  assert plume.code_from_int(4362) == plume.IoerrDirClose
  assert plume.code_from_int(1290) == plume.IoerrDirFsync
  assert plume.code_from_int(1802) == plume.IoerrFstat
  assert plume.code_from_int(1034) == plume.IoerrFsync
  assert plume.code_from_int(6410) == plume.IoerrGettemppath
  assert plume.code_from_int(3850) == plume.IoerrLock
  assert plume.code_from_int(6154) == plume.IoerrMmap
  assert plume.code_from_int(3082) == plume.IoerrNomem
  assert plume.code_from_int(2314) == plume.IoerrRdlock
}

pub fn code_from_int_unknown_returns_unexpected_error_test() {
  assert plume.code_from_int(99_999) == plume.UnexpectedError
  assert plume.code_from_int(-1) == plume.UnexpectedError
  assert plume.code_from_int(-999) == plume.UnexpectedError
}

pub fn exec_ddl_returns_zero_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE ddl_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> plume.exec(conn)

  let assert Ok(0) =
    "ALTER TABLE ddl_test ADD COLUMN email TEXT"
    |> plume.exec(conn)

  let assert Ok(0) =
    "DROP TABLE ddl_test"
    |> plume.exec(conn)
}

pub fn exec_multi_row_changes_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE multi_test (id INTEGER PRIMARY KEY, val TEXT)"
    |> plume.exec(conn)

  let assert Ok(1) = plume.exec("INSERT INTO multi_test VALUES (1, 'a')", conn)
  let assert Ok(1) = plume.exec("INSERT INTO multi_test VALUES (2, 'b')", conn)
  let assert Ok(1) = plume.exec("INSERT INTO multi_test VALUES (3, 'c')", conn)

  let assert Ok(3) =
    "UPDATE multi_test SET val = 'updated'"
    |> plume.exec(conn)

  let assert Ok(3) =
    "DELETE FROM multi_test"
    |> plume.exec(conn)
}

pub fn time_milliseconds_under_10_test() {
  use conn <- connect()

  let time = calendar.TimeOfDay(10, 20, 30, 5_000_000)

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Time(time)], conn)

  let assert Ok(["10:20:30.005"]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })
}

pub fn time_milliseconds_10_to_99_test() {
  use conn <- connect()

  let time = calendar.TimeOfDay(10, 20, 30, 50_000_000)

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Time(time)], conn)

  let assert Ok(["10:20:30.050"]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })
}

pub fn time_milliseconds_exactly_100_test() {
  use conn <- connect()

  let time = calendar.TimeOfDay(10, 20, 30, 100_000_000)

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Time(time)], conn)

  let assert Ok(["10:20:30.100"]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })
}

pub fn time_no_milliseconds_test() {
  use conn <- connect()

  let time = calendar.TimeOfDay(8, 5, 0, 0)

  let assert Ok(queried) = plume.query("SELECT ?", [plume.Time(time)], conn)

  let assert Ok(["08:05:00"]) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })
}

pub fn duration_zero_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE dur_zero_test (id INTEGER PRIMARY KEY AUTOINCREMENT, dur INTEGER)"
    |> plume.exec(conn)

  let dur = duration.seconds(0)

  let assert Ok(_) =
    "INSERT INTO dur_zero_test (dur) VALUES (?)"
    |> plume.query([plume.Duration(dur)], conn)

  let assert Ok(queried) =
    plume.query("SELECT dur FROM dur_zero_test", [], conn)

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use d <- decode.field(0, decode_duration())
      decode.success(d)
    })

  assert decoded == [dur]
}

pub fn duration_nanoseconds_only_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE dur_ns_test (id INTEGER PRIMARY KEY AUTOINCREMENT, dur INTEGER)"
    |> plume.exec(conn)

  let durations = [
    duration.nanoseconds(1),
    duration.nanoseconds(500_000_000),
    duration.nanoseconds(999_999_999),
  ]

  let assert Ok(_) = {
    use dur <- list.try_map(durations)
    "INSERT INTO dur_ns_test (dur) VALUES (?)"
    |> plume.query([plume.Duration(dur)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT dur FROM dur_ns_test ORDER BY id", [], conn)

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use d <- decode.field(0, decode_duration())
      decode.success(d)
    })

  assert durations == decoded
}

pub fn date_single_digit_day_and_month_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE date_pad_test (id INTEGER PRIMARY KEY AUTOINCREMENT, d TEXT)"
    |> plume.exec(conn)

  let dates = [
    calendar.Date(2025, calendar.January, 1),
    calendar.Date(2025, calendar.September, 9),
    calendar.Date(2025, calendar.October, 10),
    calendar.Date(2024, calendar.February, 29),
  ]

  let assert Ok(_) = {
    use date <- list.try_map(dates)
    "INSERT INTO date_pad_test (d) VALUES (?)"
    |> plume.query([plume.Date(date)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT d FROM date_pad_test ORDER BY id", [], conn)

  let assert Ok(raw) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })

  assert raw == ["2025-01-01", "2025-09-09", "2025-10-10", "2024-02-29"]

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode_date())
      decode.success(val)
    })

  assert dates == decoded
}

pub fn query_parameterized_empty_result_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE param_empty (id INTEGER PRIMARY KEY, name TEXT)"
    |> plume.exec(conn)

  let assert Ok(1) =
    "INSERT INTO param_empty VALUES (1, 'exists')"
    |> plume.exec(conn)

  let assert Ok(queried) =
    plume.query(
      "SELECT * FROM param_empty WHERE id = ?",
      [plume.Int(999)],
      conn,
    )

  assert queried.count == 0
  assert queried.rows == []
  assert queried.fields == ["id", "name"]
}

pub fn query_expression_fields_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE expr_test (id INTEGER PRIMARY KEY, name TEXT)"
    |> plume.exec(conn)

  let assert Ok(1) =
    "INSERT INTO expr_test VALUES (1, 'test')"
    |> plume.exec(conn)

  let assert Ok(queried) =
    plume.query("SELECT 1+1, COUNT(*), name AS alias FROM expr_test", [], conn)

  assert queried.count == 1
  assert queried.fields == ["1+1", "COUNT(*)", "alias"]
}

pub fn constraint_unique_error_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE uniq_test (id INTEGER PRIMARY KEY, email TEXT UNIQUE)"
    |> plume.exec(conn)

  let assert Ok(1) =
    "INSERT INTO uniq_test VALUES (1, 'a@b.com')"
    |> plume.exec(conn)

  let assert Error(plume.DbError(code, _msg, _detail, _offset)) =
    "INSERT INTO uniq_test VALUES (2, 'a@b.com')"
    |> plume.exec(conn)

  assert plume.ConstraintUnique == code
}

pub fn syntax_error_offset_test() {
  use conn <- connect()

  let assert Error(plume.DbError(_, _, _, offset)) =
    "SELEKT 1"
    |> plume.exec(conn)

  assert offset == 0

  let assert Error(plume.DbError(_, _, _, offset2)) =
    "SELECT 1 FORM users"
    |> plume.exec(conn)

  assert offset2 > 0
}

pub fn datetime_millisecond_branches_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE dt_ms_test (id INTEGER PRIMARY KEY AUTOINCREMENT, dt TEXT)"
    |> plume.exec(conn)

  let datetimes = [
    #(
      calendar.Date(2025, calendar.January, 15),
      calendar.TimeOfDay(10, 20, 30, 5_000_000),
    ),
    #(
      calendar.Date(2025, calendar.June, 15),
      calendar.TimeOfDay(10, 20, 30, 50_000_000),
    ),
    #(calendar.Date(2025, calendar.March, 1), calendar.TimeOfDay(0, 0, 0, 0)),
    #(
      calendar.Date(2025, calendar.December, 31),
      calendar.TimeOfDay(23, 59, 59, 999_000_000),
    ),
  ]

  let assert Ok(_) = {
    use dt <- list.try_map(datetimes)
    let #(date, time) = dt
    "INSERT INTO dt_ms_test (dt) VALUES (?)"
    |> plume.query([plume.Datetime(date, time)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT dt FROM dt_ms_test ORDER BY id", [], conn)

  let assert Ok(raw) =
    decode_rows(queried.rows, {
      use val <- decode.field(0, decode.string)
      decode.success(val)
    })

  assert raw
    == [
      "2025-01-15 10:20:30.005",
      "2025-06-15 10:20:30.050",
      "2025-03-01 00:00:00",
      "2025-12-31 23:59:59.999",
    ]

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use dt <- decode.field(0, decode_datetime())
      decode.success(dt)
    })

  assert datetimes == decoded
}

pub fn timestamp_negative_test() {
  use conn <- connect()

  let assert Ok(_) =
    "CREATE TABLE ts_neg_test (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT)"
    |> plume.exec(conn)

  let timestamps = [
    timestamp.from_unix_seconds(-1),
    timestamp.from_unix_seconds(-86_400),
  ]

  let assert Ok(_) = {
    use ts <- list.try_map(timestamps)
    "INSERT INTO ts_neg_test (ts) VALUES (?)"
    |> plume.query([plume.Timestamp(ts)], conn)
  }

  let assert Ok(queried) =
    plume.query("SELECT ts FROM ts_neg_test ORDER BY id", [], conn)

  let assert Ok(decoded) =
    decode_rows(queried.rows, {
      use ts <- decode.field(0, decode_timestamp())
      decode.success(ts)
    })

  assert timestamps == decoded
}

pub fn query_constraint_error_test() {
  use conn <- connect()

  let assert Ok(0) =
    "CREATE TABLE q_uniq (id INTEGER PRIMARY KEY, name TEXT UNIQUE)"
    |> plume.exec(conn)

  let assert Ok(_) =
    plume.query(
      "INSERT INTO q_uniq VALUES (?, ?)",
      [plume.Int(1), plume.Text("alice")],
      conn,
    )

  let assert Error(plume.DbError(code, msg, _detail, _offset)) =
    plume.query(
      "INSERT INTO q_uniq VALUES (?, ?)",
      [plume.Int(2), plume.Text("alice")],
      conn,
    )

  assert plume.ConstraintUnique == code
  assert msg == "UNIQUE constraint failed: q_uniq.name"
}

@external(erlang, "plume_ffi", "rescue")
fn with_rescue(next: fn() -> t) -> Result(t, Nil)
