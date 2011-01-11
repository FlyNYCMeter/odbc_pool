%% This is the application resource file (.app file) for the odbc_pool,
%% application.
{application, odbc_pool, 
  [{description, "ODBC with connection pool"},
   {vsn, "0.1.0"},
   {modules, [odbc_pool_app,
              odbc_pool_sup,
              odbc_pool]},
   {registered,[odbc_pool_sup]},
   {applications, [kernel, stdlib]},
   {mod, {odbc_pool_app,[]}},
   {env, [
   		{pool_size, 10},
   		{retry_interval, 10000},
   		{odbc_options, []},
   		{connection_string, "DSN=mssql_dev;UID=WCTempUser;PWD=WCT3mpU53r;"}
   ]},
   {start_phases, []}]}.

