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
%% Exports
%%
-export([start_link/0]).
-export([init/1]).

-define(MAX_R, 1000).
-define(MAX_T, 60).

%% @doc Start the supervisor.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%
%% Supervisor callbacks
%%
init(_) ->
	gen_event:add_handler(alarm_handler, fubar_event, []),
	EventManager = {
		fubar_event_manager,
		{gen_event, start_link, [{local, fubar_event_manager}]},
		permanent, 5000, worker, dynamic
	},
	Sysmon = {
		fubar_sysmon,
		{fubar_sysmon, start_link, []},
		permanent, 5000, worker, dynamic
	},
	Tid = ets:new(mqtt_stat, [public, ordered_set]),
	Stat = {
		mqtt_stat,
		{mqtt_stat, start_link, [[{tid, Tid}]]},
		permanent, 5000, worker, dynamic
	},
	ClientSup = {
		mqtt_client_sup,
		{mqtt_client_sup, start_link, []},
		permanent, 5000, supervisor, dynamic
	},
	{ok, {{one_for_one, ?MAX_R, ?MAX_T},
		  [EventManager, Sysmon, Stat, ClientSup]}}.
