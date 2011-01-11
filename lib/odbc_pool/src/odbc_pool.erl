%%%----------------------------------------------------------------------
%%% File    : odbc_pool.erl
%%% Author  : Boris Okner <b.okner@rogers.com>
%%% Purpose : Manage ODBC connection pool
%%% Created :  Jan 07, 2011
%%%
%%% 
%%% This code is a modification of ejabberd_odbc.erl 
%%% from ejabberd project (http://www.process-one.net/en/ejabberd/).
%%%
%%%----------------------------------------------------------------------

-module(odbc_pool).
-author('b.okner@rogers.com').

-define(GEN_FSM, gen_fsm).

-behaviour(?GEN_FSM).

%% External exports
-export([start/3, start_link/3,
         sql_query/1,
         sql_query/2,       
         sql_transaction/1,
         escape/1,       
         escape_like/1,
         to_bool/1              
        ]).

%% gen_fsm callbacks
-export([init/1,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         print_state/1,
         code_change/4]).

%% gen_fsm states
-export([connecting/2,
         connecting/3,
         session_established/2,
         session_established/3]).

-record(state, {db_ref,
                connection_string,
                odbc_options,                            
                retry_interval,
                max_pending_requests_len,
                pending_requests}).

-define(STATE_KEY, odbc_state).
-define(NESTING_KEY, odbc_nesting_level).
-define(TOP_LEVEL_TXN, 0).
-define(MAX_TRANSACTION_RESTARTS, 10).

-define(TRANSACTION_TIMEOUT, 60000). % milliseconds
-define(KEEPALIVE_TIMEOUT, 60000).
-define(KEEPALIVE_QUERY, "SELECT 1;").

%%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(ConnectionString, RetryInterval, OdbcOptions) ->
  ?GEN_FSM:start(odbc_pool, [ConnectionString, RetryInterval, OdbcOptions], []).

start_link(ConnectionString, RetryInterval, OdbcOptions) ->
  io:format("Starting connection process..."),
  ?GEN_FSM:start_link(odbc_pool, [ConnectionString, RetryInterval, OdbcOptions],
                      []).

sql_query(Query) ->
  sql_call({sql_query, Query}, ?TRANSACTION_TIMEOUT).

sql_query(Query, Timeout) ->
  sql_call({sql_query, Query}, Timeout).

%% SQL transaction based on a list of queries
%% This function automatically
sql_transaction(Queries) when is_list(Queries) ->
  F = fun() ->
           lists:foreach(fun(Query) ->
                              sql_query_t(Query)
                         end,
                         Queries)
      end,
  sql_transaction(F);
%% SQL transaction, based on a erlang anonymous function (F = fun)
sql_transaction(F) when is_function(F) ->
  sql_call({sql_transaction, F}, ?TRANSACTION_TIMEOUT).

sql_call(Msg, Timeout) ->
  ConnPid = get_random_pid(),
  case ConnPid of
    none ->
      {error, no_connections};
    _ ->
      case get(?STATE_KEY) of
        undefined ->
          ?GEN_FSM:sync_send_event(ConnPid,
                                   {sql_cmd, Msg, now()}, Timeout);
        _State ->
          nested_op(Msg)
      end
  end.

%% This function is intended to be used from inside an sql_transaction:
sql_query_t(Query) ->
  QRes = sql_query_internal(Query),
  case QRes of
    {error, Reason} ->
      throw({aborted, Reason});
    Rs when is_list(Rs) ->
      case lists:keysearch(error, 1, Rs) of
        {value, {error, Reason}} ->
          throw({aborted, Reason});
        _ ->
          QRes
      end;
    _ ->
      QRes
  end.

%% Escape character that will confuse an SQL engine
escape(S) when is_list(S) ->
  [odbc_queries:escape(C) || C <- S];
escape(S) when is_binary(S) ->
  escape(binary_to_list(S)).

%% Escape character that will confuse an SQL engine
%% Percent and underscore only need to be escaped for pattern matching like
%% statement
escape_like(S) when is_list(S) ->
  [escape_like(C) || C <- S];
escape_like($%) -> "\\%";
escape_like($_) -> "\\_";
escape_like(C)  -> odbc_queries:escape(C).

to_bool("t") -> true;
to_bool("true") -> true;
to_bool("1") -> true;
to_bool(true) -> true;
to_bool(1) -> true;
to_bool(_) -> false.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------
init([ConnectionString, RetryInterval, OdbcOptions]) ->
  ?GEN_FSM:send_event(self(), {connect, ConnectionString, OdbcOptions}),
  add_pid(self()),
  {ok, connecting, #state{
                          connection_string = ConnectionString,
                          odbc_options = OdbcOptions,                     
                          pending_requests = {0, queue:new()},
                          retry_interval = RetryInterval}}.

connecting({connect, ConnectionString, OdbcOptions}, State) ->
  ConnectRes = 
    odbc_connect(ConnectionString, OdbcOptions),
  {_, PendingRequests} = State#state.pending_requests,
  case ConnectRes of
    {ok, Ref} ->
      io:format("connected: pid=~p~n", [Ref]),
      erlang:monitor(process, Ref),
      lists:foreach(
        fun(Req) ->
             ?GEN_FSM:send_event(self(), Req)
        end, queue:to_list(PendingRequests)),
      {next_state, session_established,
       State#state{db_ref = Ref,
                   pending_requests = {0, queue:new()}}};
    {error, Reason} ->
      io:format("connection failed:~n"
                  "** Reason: ~p~n"
                    "** Retry after: ~p seconds",
                    [Reason,
                     State#state.retry_interval div 1000]),
      ?GEN_FSM:send_event_after(State#state.retry_interval,
                                {connect, ConnectionString, OdbcOptions}),
      {next_state, connecting, State}
  end;
connecting(Event, State) ->
  io:format("unexpected event in 'connecting': ~p", [Event]),
  {next_state, connecting, State}.

connecting({sql_cmd, {sql_query, ?KEEPALIVE_QUERY}, _Timestamp}, From, State) ->
  ?GEN_FSM:reply(From, {error, "SQL connection failed"}),
  {next_state, connecting, State};
connecting({sql_cmd, Command, Timestamp} = _Req, From, State) ->
  {Len, PendingRequests} = State#state.pending_requests,
  NewPendingRequests =
    if Len < State#state.max_pending_requests_len ->
         {Len + 1, queue:in({sql_cmd, Command, From, Timestamp}, PendingRequests)};
       true ->
         lists:foreach(
           fun({sql_cmd, _, To, _Timestamp}) ->
                ?GEN_FSM:reply(
                  To, {error, "SQL connection failed"})
           end, queue:to_list(PendingRequests)),
         {1, queue:from_list([{sql_cmd, Command, From, Timestamp}])}
    end,
  {next_state, connecting,
   State#state{pending_requests = NewPendingRequests}};
connecting(Request, {Who, _Ref}, State) ->
  io:format("unexpected call ~p from ~p in 'connecting'",
            [Request, Who]),
  {reply, {error, badarg}, connecting, State}.

session_established({sql_cmd, Command, Timestamp}, From, State) ->
  run_sql_cmd(Command, From, State, Timestamp);
session_established(Request, {Who, _Ref}, State) ->
  io:format("unexpected call ~p from ~p in 'session_established'",
            [Request, Who]),
  {reply, {error, badarg}, session_established, State}.

session_established({sql_cmd, Command, From, Timestamp}, State) ->
  run_sql_cmd(Command, From, State, Timestamp);
session_established(Event, State) ->
  io:format("unexpected event in 'session_established': ~p", [Event]),
  {next_state, session_established, State}.

handle_event(_Event, StateName, State) ->
  {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
  {reply, {error, badarg}, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.

%% We receive the down signal when we lose the ODBC connection (the connection process is being monitored)
handle_info({'DOWN', _MonitorRef, process, _Pid, _Info}, _StateName, 
            #state{connection_string = ConnectionString, odbc_options = OdbcOptions} = State) ->
  ?GEN_FSM:send_event(self(), {connect, ConnectionString, OdbcOptions}),
  {next_state, connecting, State};
handle_info(Info, StateName, State) ->
  io:format("unexpected info in ~p: ~p", [StateName, Info]),
  {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
  remove_pid(self()),
  ok.

%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State) ->
  State.
%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

run_sql_cmd(Command, From, State, Timestamp) ->
  case timer:now_diff(now(), Timestamp) div 1000 of
    Age when Age  < ?TRANSACTION_TIMEOUT ->
      put(?NESTING_KEY, ?TOP_LEVEL_TXN),
      put(?STATE_KEY, State),
      abort_on_driver_error(outer_op(Command), From);
    Age ->
      io:format("Database was not available or too slow,"
                  " discarding ~p milliseconds old request~n~p~n",
                  [Age, Command]),
      {next_state, session_established, State}
  end.

%% Only called by handle_call, only handles top level operations.
%% @spec outer_op(Op) -> {error, Reason} | {aborted, Reason} | {atomic, Result}
outer_op({sql_query, Query}) ->
  sql_query_internal(Query);
outer_op({sql_transaction, F}) ->
  outer_transaction(F, ?MAX_TRANSACTION_RESTARTS, "").

%% Called via sql_query/transaction/bloc from client code when inside a
%% nested operation
nested_op({sql_query, Query}) ->
  %% XXX - use sql_query_t here insted? Most likely would break
  %% callers who expect {error, _} tuples (sql_query_t turns
  %% these into throws)
  sql_query_internal(Query);
nested_op({sql_transaction, F}) ->
  NestingLevel = get(?NESTING_KEY),
  if NestingLevel =:= ?TOP_LEVEL_TXN ->
       %% First transaction inside a (series of) sql_blocs
       outer_transaction(F, ?MAX_TRANSACTION_RESTARTS, "");
     true ->
       %% Transaction inside a transaction
       inner_transaction(F)
  end.

%% Never retry nested transactions - only outer transactions
inner_transaction(F) ->
  PreviousNestingLevel = get(?NESTING_KEY),
  case get(?NESTING_KEY) of
    ?TOP_LEVEL_TXN ->
      {backtrace, T} = process_info(self(), backtrace),
      io:format("inner transaction called at outer txn level. Trace: ~s",
                [T]),
      erlang:exit(implementation_faulty);
    _N -> ok
  end,
  put(?NESTING_KEY, PreviousNestingLevel + 1),
  Result = (catch F()),
  put(?NESTING_KEY, PreviousNestingLevel),
  case Result of
    {aborted, Reason} ->
      {aborted, Reason};
    {'EXIT', Reason} ->
      {'EXIT', Reason};
    {atomic, Res} ->
      {atomic, Res};
    Res ->
      {atomic, Res}
  end.

outer_transaction(F, NRestarts, _Reason) ->
  PreviousNestingLevel = get(?NESTING_KEY),
  case get(?NESTING_KEY) of
    ?TOP_LEVEL_TXN ->
      ok;
    _N ->
      %%{backtrace, T} = process_info(self(), backtrace),
      erlang:exit(implementation_faulty)
  end,
  sql_query_internal("begin;"),
  put(?NESTING_KEY, PreviousNestingLevel + 1),
  Result = (catch F()),
  put(?NESTING_KEY, PreviousNestingLevel),
  case Result of
    {aborted, Reason} when NRestarts > 0 ->
      %% Retry outer transaction upto NRestarts times.
      sql_query_internal("rollback;"),
      outer_transaction(F, NRestarts - 1, Reason);
    {aborted, Reason} when NRestarts =:= 0 ->
      %% Too many retries of outer transaction.
      io:format("SQL transaction restarts exceeded~n"
                  "** Restarts: ~p~n"
                    "** Last abort reason: ~p~n"
                      "** Stacktrace: ~p~n"
                        "** When State == ~p",
                        [?MAX_TRANSACTION_RESTARTS, Reason,
                         erlang:get_stacktrace(), get(?STATE_KEY)]),
      sql_query_internal("rollback;"),
      {aborted, Reason};
    {'EXIT', Reason} ->
      %% Abort sql transaction on EXIT from outer txn only.
      sql_query_internal("rollback;"),
      {aborted, Reason};
    Res ->
      %% Commit successful outer txn
      sql_query_internal("commit;"),
      {atomic, Res}
  end.

sql_query_internal(Query) ->
  State = get(?STATE_KEY),
  Res = odbc:sql_query(State#state.db_ref, Query),
  
  case Res of
    {error, "No SQL-driver information available."} ->
      % workaround for odbc bug
      {updated, 0};
    _Else -> Res
  end.

%% Generate the OTP callback return tuple depending on the driver result.
abort_on_driver_error({error, "query timed out"} = Reply, From) ->
  %%  driver error
  ?GEN_FSM:reply(From, Reply),
  {stop, timeout, get(?STATE_KEY)};
abort_on_driver_error({error, "Failed sending data on socket" ++ _} = Reply,
                      From) ->
  %%  driver error
  ?GEN_FSM:reply(From, Reply),
  {stop, closed, get(?STATE_KEY)};
abort_on_driver_error(Reply, From) ->
  ?GEN_FSM:reply(From, Reply),
  {next_state, session_established, get(?STATE_KEY)}.


%% == pure ODBC code

%% part of init/1
%% Open an ODBC database connection
odbc_connect(SQLServer, OdbcOptions) ->
  application:start(odbc),
  odbc:connect(SQLServer, OdbcOptions).

%% Helpers
get_pids() ->
  case ets:info(sql_pool) of 
    undefined -> [];
    _ ->
      Rs = ets:tab2list(sql_pool),
      [R || {R} <- Rs]
  end.

get_random_pid() ->
  Pids = get_pids(),
  lists:nth(erlang:phash(now(), length(Pids)), Pids).

add_pid(Pid) ->
  case ets:info(sql_pool) of 
    undefined ->
      ets:new(sql_pool, [bag, puplic, named_table]);
    _ ->
      ok
  end, 
  ets:insert(sql_pool, {Pid}).

remove_pid(Pid) ->
  case ets:info(sql_pool) of
    undefined ->
      ok;
    _ -> 
      ets:delete(sql_pool, {Pid})
  end.
