%%%----------------------------------------------------------------
%%% @author  Boris Okner <b.okner@rogers.com>
%%% @doc
%%% @end
%%% @copyright 2011 Boris Okner
%%%----------------------------------------------------------------
-module(odbc_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).
%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
	ets:new(sql_pool, [bag, public, named_table]),
	supervisor:start_link({local, ?SERVER}, ?MODULE, []).


%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 1000,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},


%%     AChild = {'AName', {'AModule', start_link, []},
%%               Restart, Shutdown, Type, ['AModule']},
   {ok, PoolSize} = application:get_env(pool_size), 
   {ok, RetryInterval} = application:get_env(retry_interval),
   {ok, Options} = application:get_env(odbc_options), 
   {ok, ConnectionString} = application:get_env(connection_string), 
	  Children = lists:map(
	    fun(I) ->
		    {list_to_atom("odbc_pool_" ++ integer_to_list(I)),
		     {odbc_pool, start_link, [ConnectionString, RetryInterval, Options]},
		     permanent,
		     brutal_kill,
		     worker,
		     [odbc_pool]}
	    end, lists:seq(1, PoolSize)),    
    {ok, {SupFlags, Children}}.



%%%===================================================================
%%% Internal functions
%%%===================================================================

