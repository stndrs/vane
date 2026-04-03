import gleam/dynamic.{type Dynamic}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/list
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp

/// A connection to a SQLite database. Create one with `open` and release it
/// with `close` when you're done.
pub opaque type Connection {
  Database(config: Config)
  Connection(ref: Reference)
}

/// Global SQLite memory statistics returned by `status`.
pub type StatusInfo {
  StatusInfo(
    memory_used: Stats,
    pagecache_used: Stats,
    pagecache_overflow: Stats,
    malloc_size: Stats,
    parser_stack: Stats,
    pagecache_size: Stats,
    malloc_count: Stats,
  )
}

/// A pair of current and highwater values for a SQLite status metric.
pub type Stats {
  Stats(used: Int, highwater: Int)
}

/// Returns global SQLite memory and resource usage statistics.
@external(erlang, "plume_ffi", "status")
pub fn status() -> StatusInfo

/// Configuration for opening a database connection.
pub type Config {
  Config(db: String)
}

/// Creates a `Config` for the given database path. Pass `":memory:"` for an
/// in-memory database, or a file path for a persistent one.
pub fn config(db: String) -> Config {
  Config(db:)
}

/// Returns a `Connection`. This function does not open a connection to
/// the configured sqlite database. Passing the `Connection` record
/// to a query function (e.g. `plume.query`) will open the connection,
/// perform the query, and then close the connection.
pub fn new(config: Config) -> Connection {
  Database(config:)
}

/// Connects to the configured sqlite database and remains open until the callback
/// completes.
pub fn with_connection(
  config: Config,
  next: fn(Connection) -> t,
) -> Result(t, PlumeError) {
  charlist.from_string(config.db)
  |> open_
  |> result.map(fn(ref) {
    let res = Connection(ref:) |> next

    let _ = close_(ref)

    res
  })
}

/// Errors returned by plume operations.
pub type PlumeError {
  /// The database connection could not be opened.
  ConnectionFailed
  /// The connection was already closed.
  ConnectionUnavailable
  /// SQLite error
  DbError(code: Code, message: String, detail: String, offset: Int)
}

/// Formats a `PlumeError` as a human-readable string suitable for logging.
pub fn error_to_string(err: PlumeError) -> String {
  case err {
    ConnectionFailed -> "[plume.ConnectionFailed]"
    ConnectionUnavailable -> "[plume.ConnectionUnavailable]"
    DbError(code:, message:, detail:, offset: _) -> {
      "[plume.DbError] code: "
      <> code_to_string(code)
      <> ", message: "
      <> message
      <> ", detail: "
      <> detail
    }
  }
}

/// A value to bind to a query parameter. Each variant maps to a SQLite type:
pub type Value {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  Text(String)
  Bytea(BitArray)
  Time(calendar.TimeOfDay)
  Date(calendar.Date)
  Datetime(calendar.Date, calendar.TimeOfDay)
  Timestamp(timestamp.Timestamp)
  Duration(duration.Duration)
}

/// The result of a `query` call. Contains the number of rows returned, the
/// column names, and the rows themselves as `Dynamic` values for decoding.
pub type Queried {
  Queried(count: Int, fields: List(String), rows: List(Dynamic))
}

/// Opens a new connection to the database specified in `conf`.
pub fn open(conf: Config) -> Result(Connection, PlumeError) {
  charlist.from_string(conf.db)
  |> open_
  |> result.map(Connection)
}

/// Closes a database connection. Returns `Ok(Nil)` on success, or
/// `Error(Nil)` if the connection was already closed.
pub fn close(conn: Connection) -> Result(Nil, Nil) {
  case conn {
    Database(_) -> Ok(Nil)
    Connection(ref:) -> close_(ref)
  }
}

fn with_single_connection(
  conn: Connection,
  next: fn(Reference) -> Result(t, PlumeError),
) -> Result(t, PlumeError) {
  case conn {
    Database(config:) -> {
      charlist.from_string(config.db)
      |> open_
      |> result.try(fn(ref) {
        let res = next(ref)

        let _ = close_(ref)

        res
      })
    }
    Connection(ref:) -> next(ref)
  }
}

/// Executes a query with positional parameter binding and returns the result
/// rows. Use `?` placeholders in the SQL and pass values in the same order.
pub fn query(
  sql: String,
  values: List(Value),
  conn: Connection,
) -> Result(Queried, PlumeError) {
  use ref <- with_single_connection(conn)
  use stmt <- result.try(prepare(sql, ref, []))

  fetch_rows(stmt, values, ref)
  |> result.map(fn(rows) {
    let count = list.length(rows)
    let fields = column_names_(stmt)

    Queried(count:, fields:, rows:)
  })
}

// not in use
type PrepareFlag {
  Persistent
  NoVtab
}

fn prepare(
  sql: String,
  ref: Reference,
  flags: List(PrepareFlag),
) -> Result(Reference, PlumeError) {
  prepare_flag_value(flags)
  |> prepare_(ref, sql, _)
}

const no_vtab = 0x04

const persistent = 0x01

fn prepare_flag_value(flags: List(PrepareFlag)) -> Int {
  case flags {
    [] -> 0
    [NoVtab] -> no_vtab
    [Persistent] -> int.bitwise_or(0, persistent)
    [_, _] -> int.bitwise_or(no_vtab, persistent)
    _ -> 0
  }
}

fn fetch_rows(
  stmt: Reference,
  args: List(Value),
  ref: Reference,
) -> Result(List(Dynamic), PlumeError) {
  case args {
    [] -> fetchall_(stmt, ref)
    vals -> bind(stmt, vals) |> result.try(fetchall_(_, ref))
  }
}

fn bind(
  statement: Reference,
  args: List(Value),
) -> Result(Reference, PlumeError) {
  args
  |> list.index_map(fn(arg, idx) { #(idx, arg) })
  |> list.try_fold(from: statement, with: fn(stmt, arg) {
    let idx = arg.0 + 1

    case arg.1 {
      Null -> bind_null(stmt, idx)
      Bool(val) -> bind_bool(stmt, idx, val)
      Int(val) -> bind_int(stmt, idx, val)
      Float(val) -> bind_double(stmt, idx, val)
      Text(val) -> bind_text(stmt, idx, val)
      Bytea(val) -> bind_blob(stmt, idx, val)
      Date(val) -> bind_date(stmt, idx, val)
      Time(val) -> bind_time(stmt, idx, val)
      Datetime(date, time) -> bind_datetime(stmt, idx, date, time)
      Timestamp(val) -> bind_timestamp(stmt, idx, val)
      Duration(val) -> bind_duration(stmt, idx, val)
    }
  })
}

fn date_to_string(date: calendar.Date) -> String {
  format_date(date)
}

fn datetime_to_string(dt: calendar.Date, tod: calendar.TimeOfDay) -> String {
  let date = format_date(dt)
  let time = format_time(tod)

  { date <> " " <> time }
}

fn time_to_string(tod: calendar.TimeOfDay) -> String {
  format_time(tod)
}

fn format_date(date: calendar.Date) -> String {
  let year = int.to_string(date.year)
  let month = calendar.month_to_int(date.month) |> pad_zero
  let day = pad_zero(date.day)

  year <> "-" <> month <> "-" <> day
}

fn format_time(tod: calendar.TimeOfDay) -> String {
  let hours = pad_zero(tod.hours)
  let minutes = pad_zero(tod.minutes)
  let seconds = pad_zero(tod.seconds)
  let milliseconds = tod.nanoseconds / 1_000_000

  let msecs = case milliseconds < 100 {
    True if milliseconds == 0 -> ""
    True if milliseconds < 10 -> ".00" <> int.to_string(milliseconds)
    True -> ".0" <> int.to_string(milliseconds)
    False -> "." <> int.to_string(milliseconds)
  }

  hours <> ":" <> minutes <> ":" <> seconds <> msecs
}

fn pad_zero(n: Int) -> String {
  case n >= 0 && n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

fn bind_bool(
  stmt: Reference,
  idx: Int,
  bool: Bool,
) -> Result(Reference, PlumeError) {
  case bool {
    True -> 1
    False -> 0
  }
  |> bind_int(stmt, idx, _)
}

fn bind_date(
  stmt: Reference,
  idx: Int,
  date: calendar.Date,
) -> Result(Reference, PlumeError) {
  date_to_string(date)
  |> bind_text(stmt, idx, _)
}

fn bind_time(
  stmt: Reference,
  idx: Int,
  tod: calendar.TimeOfDay,
) -> Result(Reference, PlumeError) {
  time_to_string(tod)
  |> bind_text(stmt, idx, _)
}

fn bind_datetime(
  stmt: Reference,
  idx: Int,
  date: calendar.Date,
  tod: calendar.TimeOfDay,
) -> Result(Reference, PlumeError) {
  datetime_to_string(date, tod)
  |> bind_text(stmt, idx, _)
}

fn bind_timestamp(
  stmt: Reference,
  idx: Int,
  ts: timestamp.Timestamp,
) -> Result(Reference, PlumeError) {
  timestamp.to_rfc3339(ts, calendar.utc_offset)
  |> bind_text(stmt, idx, _)
}

fn bind_duration(
  stmt: Reference,
  idx: Int,
  dur: duration.Duration,
) -> Result(Reference, PlumeError) {
  let #(sec, nsec) = duration.to_seconds_and_nanoseconds(dur)
  let nsec = { sec * 1_000_000_000 } + nsec

  bind_int(stmt, idx, nsec)
}

fn bind_null(stmt: Reference, idx: Int) -> Result(Reference, PlumeError) {
  bind_null_(stmt, idx)
  |> result.replace(stmt)
}

fn bind_text(
  stmt: Reference,
  idx: Int,
  val: String,
) -> Result(Reference, PlumeError) {
  bind_text_(stmt, idx, val)
  |> result.replace(stmt)
}

fn bind_int(
  stmt: Reference,
  idx: Int,
  val: Int,
) -> Result(Reference, PlumeError) {
  bind_int_(stmt, idx, val)
  |> result.replace(stmt)
}

fn bind_double(
  stmt: Reference,
  idx: Int,
  val: Float,
) -> Result(Reference, PlumeError) {
  bind_double_(stmt, idx, val)
  |> result.replace(stmt)
}

fn bind_blob(
  stmt: Reference,
  idx: Int,
  val: BitArray,
) -> Result(Reference, PlumeError) {
  bind_blob_(stmt, idx, val)
  |> result.replace(stmt)
}

/// Executes a SQL statement. Returns the number of rows changed.
pub fn execute(sql: String, on conn: Connection) -> Result(Int, PlumeError) {
  use ref <- with_single_connection(conn)

  exec_(ref, sql)
  |> result.map(changes_)
}

/// Errors specific to transaction operations.
pub type TransactionError(error) {
  /// The callback returns `Error` so the transaction was rolled back.
  RollbackError(cause: error)
  /// A transaction operation was attempted outside of a transaction.
  NotInTransaction
  /// BEGIN, COMMIT, or ROLLBACK failed.
  TransactionError(message: String)
}

/// Runs `next` inside a BEGIN/COMMIT transaction. If `next` returns `Error`,
/// the transaction is rolled back and the error is wrapped in `RollbackError`.
/// If `next` crashes, the transaction is still safely rolled back.
pub fn transaction(
  conn: Connection,
  next: fn(Connection) -> Result(t, error),
) -> Result(t, TransactionError(error)) {
  case conn {
    Database(config:) -> {
      charlist.from_string(config.db)
      |> open_
      |> result.map_error(fn(err) {
        err
        |> error_to_string
        |> TransactionError
      })
      |> result.try(fn(ref) {
        let tx = Connection(ref:)

        use ref <- result.try(begin(ref))

        let res =
          handle_crash_(fn() { rollback(ref) }, fn() { next(tx) })
          |> result.map_error(fn(err) {
            case rollback(ref) {
              Ok(_tx) -> RollbackError(err)
              Error(err) -> err
            }
          })
          |> result.try(fn(res) { commit(ref) |> result.replace(res) })

        let _ = close_(ref)

        res
      })
    }
    Connection(ref:) -> {
      use ref <- result.try(begin(ref))

      handle_crash_(fn() { rollback(ref) }, fn() { next(conn) })
      |> result.map_error(fn(err) {
        case rollback(ref) {
          Ok(_tx) -> RollbackError(err)
          Error(err) -> err
        }
      })
      |> result.try(fn(res) { commit(ref) |> result.replace(res) })
    }
  }
}

fn begin(ref: Reference) -> Result(Reference, TransactionError(error)) {
  exec_(ref, "BEGIN")
  |> result.map_error(fn(err) { error_to_string(err) |> TransactionError })
}

fn commit(ref: Reference) -> Result(Reference, TransactionError(error)) {
  exec_(ref, "COMMIT")
  |> result.map_error(fn(err) { error_to_string(err) |> TransactionError })
}

fn rollback(ref: Reference) -> Result(Reference, TransactionError(error)) {
  exec_(ref, "ROLLBACK")
  |> result.map_error(fn(err) { error_to_string(err) |> TransactionError })
}

/// SQLite result codes. Includes both primary codes (e.g. `Busy`, `Constraint`)
/// and extended codes (e.g. `BusyTimeout`, `ConstraintUnique`).
pub type Code {
  Abort
  Auth
  Busy
  Cantopen
  Constraint
  Corrupt
  Done
  Empty
  GenericError
  Format
  Full
  Internal
  Interrupt
  Ioerr
  Locked
  Mismatch
  Misuse
  Nolfs
  Nomem
  Notadb
  Notfound
  Notice
  GenericOk
  Perm
  Protocol
  Range
  Readonly
  Row
  Schema
  Toobig
  Warning
  AbortRollback
  AuthUser
  BusyRecovery
  BusySnapshot
  BusyTimeout
  CantopenConvpath
  CantopenDirtywal
  CantopenFullpath
  CantopenIsdir
  CantopenNotempdir
  CantopenSymlink
  ConstraintCheck
  ConstraintCommithook
  ConstraintDatatype
  ConstraintForeignkey
  ConstraintFunction
  ConstraintNotnull
  ConstraintPinned
  ConstraintPrimarykey
  ConstraintRowid
  ConstraintTrigger
  ConstraintUnique
  ConstraintVtab
  CorruptIndex
  CorruptSequence
  CorruptVtab
  ErrorMissingCollseq
  ErrorRetry
  ErrorSnapshot
  IoerrAccess
  IoerrAuth
  IoerrBeginAtomic
  IoerrBlocked
  IoerrCheckreservedlock
  IoerrClose
  IoerrCommitAtomic
  IoerrConvpath
  IoerrCorruptfs
  IoerrData
  IoerrDelete
  IoerrDeleteNoent
  IoerrDirClose
  IoerrDirFsync
  IoerrFstat
  IoerrFsync
  IoerrGettemppath
  IoerrLock
  IoerrMmap
  IoerrNomem
  IoerrRdlock
  UnexpectedError
}

fn code_to_string(code: Code) -> String {
  case code {
    Abort -> "ABORT"
    Auth -> "AUTH"
    Busy -> "BUSY"
    Cantopen -> "CANTOPEN"
    Constraint -> "CONSTRAINT"
    Corrupt -> "CORRUPT"
    Done -> "DONE"
    Empty -> "EMPTY"
    GenericError -> "ERROR"
    Format -> "FORMAT"
    Full -> "FULL"
    Internal -> "INTERNAL"
    Interrupt -> "INTERRUPT"
    Ioerr -> "IOERR"
    Locked -> "LOCKED"
    Mismatch -> "MISMATCH"
    Misuse -> "MISUSE"
    Nolfs -> "NOLFS"
    Nomem -> "NOMEM"
    Notadb -> "NOTADB"
    Notfound -> "NOTFOUND"
    Notice -> "NOTICE"
    GenericOk -> "OK"
    Perm -> "PERM"
    Protocol -> "PROTOCOL"
    Range -> "RANGE"
    Readonly -> "READONLY"
    Row -> "ROW"
    Schema -> "SCHEMA"
    Toobig -> "TOOBIG"
    Warning -> "WARNING"
    AbortRollback -> "ABORT_ROLLBACK"
    AuthUser -> "AUTH_USER"
    BusyRecovery -> "BUSY_RECOVERY"
    BusySnapshot -> "BUSY_SNAPSHOT"
    BusyTimeout -> "BUSY_TIMEOUT"
    CantopenConvpath -> "CANTOPEN_CONVPATH"
    CantopenDirtywal -> "CANTOPEN_DIRTYWAL"
    CantopenFullpath -> "CANTOPEN_FULLPATH"
    CantopenIsdir -> "CANTOPEN_ISDIR"
    CantopenNotempdir -> "CANTOPEN_NOTEMPDIR"
    CantopenSymlink -> "CANTOPEN_SYMLINK"
    ConstraintCheck -> "CONSTRAINT_CHECK"
    ConstraintCommithook -> "CONSTRAINT_COMMITHOOK"
    ConstraintDatatype -> "CONSTRAINT_DATATYPE"
    ConstraintForeignkey -> "CONSTRAINT_FOREIGNKEY"
    ConstraintFunction -> "CONSTRAINT_FUNCTION"
    ConstraintNotnull -> "CONSTRAINT_NOTNULL"
    ConstraintPinned -> "CONSTRAINT_PINNED"
    ConstraintPrimarykey -> "CONSTRAINT_PRIMARYKEY"
    ConstraintRowid -> "CONSTRAINT_ROWID"
    ConstraintTrigger -> "CONSTRAINT_TRIGGER"
    ConstraintUnique -> "CONSTRAINT_UNIQUE"
    ConstraintVtab -> "CONSTRAINT_VTAB"
    CorruptIndex -> "CORRUPT_INDEX"
    CorruptSequence -> "CORRUPT_SEQUENCE"
    CorruptVtab -> "CORRUPT_VTAB"
    ErrorMissingCollseq -> "ERROR_MISSING_COLLSEQ"
    ErrorRetry -> "ERROR_RETRY"
    ErrorSnapshot -> "ERROR_SNAPSHOT"
    IoerrAccess -> "IOERR_ACCESS"
    IoerrAuth -> "IOERR_AUTH"
    IoerrBeginAtomic -> "IOERR_BEGIN_ATOMIC"
    IoerrBlocked -> "IOERR_BLOCKED"
    IoerrCheckreservedlock -> "IOERR_CHECKRESERVEDLOCK"
    IoerrClose -> "IOERR_CLOSE"
    IoerrCommitAtomic -> "IOERR_COMMIT_ATOMIC"
    IoerrConvpath -> "IOERR_CONVPATH"
    IoerrCorruptfs -> "IOERR_CORRUPTFS"
    IoerrData -> "IOERR_DATA"
    IoerrDelete -> "IOERR_DELETE"
    IoerrDeleteNoent -> "IOERR_DELETE_NOENT"
    IoerrDirClose -> "IOERR_DIR_CLOSE"
    IoerrDirFsync -> "IOERR_DIR_FSYNC"
    IoerrFstat -> "IOERR_FSTAT"
    IoerrFsync -> "IOERR_FSYNC"
    IoerrGettemppath -> "IOERR_GETTEMPPATH"
    IoerrLock -> "IOERR_LOCK"
    IoerrMmap -> "IOERR_MMAP"
    IoerrNomem -> "IOERR_NOMEM"
    IoerrRdlock -> "IOERR_RDLOCK"
    UnexpectedError -> "UNEXPECTED_ERROR"
  }
}

/// Converts a numeric SQLite result code to the corresponding `Code` variant.
/// Returns `UnexpectedError` for unrecognised values. This function is
/// internal and not part of the public API.
@internal
pub fn code_from_int(code: Int) -> Code {
  case code {
    4 -> Abort
    23 -> Auth
    5 -> Busy
    14 -> Cantopen
    19 -> Constraint
    11 -> Corrupt
    101 -> Done
    16 -> Empty
    1 -> GenericError
    24 -> Format
    13 -> Full
    2 -> Internal
    9 -> Interrupt
    10 -> Ioerr
    6 -> Locked
    20 -> Mismatch
    21 -> Misuse
    22 -> Nolfs
    7 -> Nomem
    26 -> Notadb
    12 -> Notfound
    27 -> Notice
    0 -> GenericOk
    3 -> Perm
    15 -> Protocol
    25 -> Range
    8 -> Readonly
    100 -> Row
    17 -> Schema
    18 -> Toobig
    28 -> Warning
    516 -> AbortRollback
    279 -> AuthUser
    261 -> BusyRecovery
    517 -> BusySnapshot
    773 -> BusyTimeout
    1038 -> CantopenConvpath
    1294 -> CantopenDirtywal
    782 -> CantopenFullpath
    526 -> CantopenIsdir
    270 -> CantopenNotempdir
    1550 -> CantopenSymlink
    275 -> ConstraintCheck
    531 -> ConstraintCommithook
    3091 -> ConstraintDatatype
    787 -> ConstraintForeignkey
    1043 -> ConstraintFunction
    1299 -> ConstraintNotnull
    2835 -> ConstraintPinned
    1555 -> ConstraintPrimarykey
    2579 -> ConstraintRowid
    1811 -> ConstraintTrigger
    2067 -> ConstraintUnique
    2323 -> ConstraintVtab
    779 -> CorruptIndex
    523 -> CorruptSequence
    267 -> CorruptVtab
    257 -> ErrorMissingCollseq
    513 -> ErrorRetry
    769 -> ErrorSnapshot
    3338 -> IoerrAccess
    7178 -> IoerrAuth
    7434 -> IoerrBeginAtomic
    2826 -> IoerrBlocked
    3594 -> IoerrCheckreservedlock
    4106 -> IoerrClose
    7690 -> IoerrCommitAtomic
    6666 -> IoerrConvpath
    8458 -> IoerrCorruptfs
    8202 -> IoerrData
    2570 -> IoerrDelete
    5898 -> IoerrDeleteNoent
    4362 -> IoerrDirClose
    1290 -> IoerrDirFsync
    1802 -> IoerrFstat
    1034 -> IoerrFsync
    6410 -> IoerrGettemppath
    3850 -> IoerrLock
    6154 -> IoerrMmap
    3082 -> IoerrNomem
    2314 -> IoerrRdlock
    _ -> UnexpectedError
  }
}

// FFI

@external(erlang, "plume_ffi", "handle_crash")
fn handle_crash_(handler: fn() -> a, next: fn() -> b) -> b

@external(erlang, "plume_ffi", "open")
fn open_(a: Charlist) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "close")
fn close_(a: Reference) -> Result(Nil, Nil)

// Bind

@external(erlang, "plume_ffi", "bind_null")
fn bind_null_(s: Reference, col: Int) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "bind_int")
fn bind_int_(
  s: Reference,
  col: Int,
  value: Int,
) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "bind_text")
fn bind_text_(
  s: Reference,
  col: Int,
  value: String,
) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "bind_double")
fn bind_double_(
  s: Reference,
  col: Int,
  value: Float,
) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "bind_blob")
fn bind_blob_(
  s: Reference,
  col: Int,
  value: BitArray,
) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "prepare")
fn prepare_(
  conn: Reference,
  sql: String,
  flags: Int,
) -> Result(Reference, PlumeError)

@external(erlang, "plume_ffi", "fetchall")
fn fetchall_(
  statement: Reference,
  conn: Reference,
) -> Result(List(Dynamic), PlumeError)

@external(erlang, "esqlite3_nif", "column_names")
fn column_names_(statement: Reference) -> List(String)

@external(erlang, "plume_ffi", "exec")
fn exec_(conn: Reference, sql: String) -> Result(Reference, PlumeError)

@external(erlang, "esqlite3_nif", "changes")
fn changes_(conn: Reference) -> Int
