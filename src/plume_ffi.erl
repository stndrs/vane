-module(plume_ffi).

-export([
  bind_null/2,
  bind_int/3,
  bind_text/3,
  bind_double/3,
  bind_blob/3,
  open/1,
  exec/2,
  prepare/3,
  status/0,
  fetchall/2,
  close/1,
  rescue/1,
  handle_crash/2
]).

open(Database) ->
  case esqlite3_nif:open(Database) of
    {ok, Ref} -> {ok, Ref};
    {error, _} -> {error, connection_failed}
  end.

close(Connection) ->
  try
    esqlite3_nif:close(Connection),
    {ok, nil}
  catch _:_ ->
    {error, nil}
  end.

fetchall(Statement, Connection) ->
  case fetchall1(Statement, Connection, []) of
    {error, _} = E -> E;
    Rows -> {ok, lists:map(fun erlang:list_to_tuple/1, Rows)}
  end.

fetchall1(Statement, Connection, Acc) ->
  case esqlite3_nif:step(Statement) of
    Row when is_list(Row) -> fetchall1(Statement, Connection, [Row|Acc]);
    '$done' -> lists:reverse(Acc);
    {error, Code} -> code_to_error(Connection, Code)
  end.

stats(#{used := Used, highwater := Highwater}) ->
  {stats, Used, Highwater}.

status() ->
  #{memory_used := MemoryUsed,
    pagecache_used := PagecacheUsed,
    pagecache_overflow := PagecacheOverflow,
    malloc_size := MallocSize,
    parser_stack := ParserStack,
    pagecache_size := PagecacheSize,
    malloc_count := MallocCount} =
    esqlite3:status(),
  {status_info,
   stats(MemoryUsed),
   stats(PagecacheUsed),
   stats(PagecacheOverflow),
   stats(MallocSize),
   stats(ParserStack),
   stats(PagecacheSize),
   stats(MallocCount)}.

code_to_error(Connection, Code) when is_integer(Code) ->
  try
    #{errmsg := Message, error_offset := Offset, errstr := ErrorString} = esqlite3_nif:error_info(Connection),
    Code1 = plume:code_from_int(Code),
    {error, {db_error, Code1, Message, ErrorString, Offset}}
  catch _:_
    -> {error, connection_unavailable}
  end.

% --- Query --- %

prepare(Ref, Sql, Flags) ->
  try esqlite3_nif:prepare(Ref, Sql, Flags) of
    {ok, Statement} -> {ok, Statement};
    {error, Code} -> code_to_error(Ref, Code)
  catch _:_ ->
    {error, connection_unavailable}
  end.

exec(Ref, Sql) ->
  try esqlite3_nif:exec(Ref, Sql) of
    ok -> {ok, Ref};
    {error, Code} -> code_to_error(Ref, Code)
  catch _:_ ->
    {error, connection_unavailable}
  end.

% --- Bind --- %

bind_null(Ref, Col) ->
  case esqlite3_nif:bind_null(Ref, Col) of
    ok -> {ok, Ref};
    {error, Code} -> code_to_error(Ref, Code)
  end.

bind_int(Ref, Col, Value) ->
  case esqlite3_nif:bind_int64(Ref, Col, Value) of
    ok -> {ok, Ref};
    {error, Code} -> code_to_error(Ref, Code)
  end.

bind_text(Ref, Col, Value) ->
  case esqlite3_nif:bind_text(Ref, Col, Value) of
    ok -> {ok, Ref};
    {error, Code} -> code_to_error(Ref, Code)
  end.

bind_double(Ref, Col, Value) ->
  case esqlite3_nif:bind_double(Ref, Col, Value) of
    ok -> {ok, Ref};
    {error, Code} -> code_to_error(Ref, Code)
  end.

bind_blob(Ref, Col, Value) ->
  case esqlite3_nif:bind_blob(Ref, Col, Value) of
    ok -> {ok, Ref};
    {error, Code} -> code_to_error(Ref, Code)
  end.

rescue(Fun) ->
  try {ok, Fun()}
  catch _:_:_ -> {error, nil}
  end.

handle_crash(Handler, Fun) ->
  try Fun()
  catch Class:Reason:Stacktrace ->
    Handler(),
    erlang:raise(Class, Reason, Stacktrace)
  end.
