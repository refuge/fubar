%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar supervisor callback.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(fubar_sup).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(supervisor).

%%
%% Includes
%%
-include("fubar.hrl").

-define(MAX_R, 3).
-define(MAX_T, 5).

%%
%% Exports
%%
-export([start_link/0]).
-export([init/1]).

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%
%% Supervisor callbacks
%%
init(_) ->
	alarm_handler:add_alarm_handler(fubar_alarm, []),
	LogManager = {fubar_log, {fubar_log, start_link, []}, permanent, brutal_kill, worker, dynamic},
	MemoryMonitor = {vm_memory_monitor, {vm_memory_monitor, start_link, []}, permanent, brutal_kill, worker, dynamic},
	{ok, {{one_for_one, ?MAX_R, ?MAX_T}, [LogManager, MemoryMonitor]}}.