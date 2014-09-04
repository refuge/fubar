%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar application callback.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(fubar_app).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(application).

%%
%% Callbacks
%%
-export([start/2, stop/1]).

-include("props_to_record.hrl").

-define(APPLICATION, fubar).

%%
%% Records
%%
-record(?MODULE, {acceptors = 100 :: integer(),
				  max_connections = infinity :: timeout(),
				  options = []}).

start_mqtt_listener(EnvPort, Settings) ->
	Port = application:get_env(?APPLICATION, EnvPort),

	MaxConnections = Settings#?MODULE.max_connections,
	Options = Settings#?MODULE.options,
	Acceptors = Settings#?MODULE.acceptors,

	case {Port, MaxConnections} of
		{undefined, _} ->
			ok;
		_ ->
			ranch:start_listener(
				mqtt,
				Acceptors,
				ranch_tcp,
				[{port, Port}, {max_connections, MaxConnections} | Options],
				mqtt_protocol,
				[{dispatch, mqtt_server}]
			)
	end.

start_mqtts_listener(EnvPort, Settings) ->
	Port = application:get_env(?APPLICATION, EnvPort),

	MaxConnections = Settings#?MODULE.max_connections,
	Options = Settings#?MODULE.options,
	Acceptors = Settings#?MODULE.acceptors,

	case {Port, MaxConnections} of
		{undefined, _} -> ok;
		_ ->
			ranch:start_listener(
				mqtts,
				Acceptors,
				ranch_ssl,
				[{port, Port}, {max_connections, MaxConnections} | Options],
				mqtt_protocol,
				[{dispatch, mqtt_server}]
			)
	end.

start_websocket_listener(EnvPort, Settings) ->
	Port = application:get_env(?APPLICATION, EnvPort),

	MaxConnections = Settings#?MODULE.max_connections,
	Options = Settings#?MODULE.options,
	Acceptors = Settings#?MODULE.acceptors,

	case {Port, MaxConnections} of
		{undefined, _} -> ok;
		_ ->
			Dispatch = cowboy_router:compile([
				{'_', [
					{"/websocket", websocket_protocol, [{dispatch, mqtt_server}]}
				]}
			]),

			cowboy:start_http(
				http,
				Acceptors,
				[{port, Port}, {max_connections, MaxConnections} | Options],
				[{env, [{dispatch, Dispatch}]}]
			)
	end.

%%
%% Application callbacks
%%
start(_StartType, _StartArgs) ->
	Settings = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),

	{ok, Pid} = fubar_sup:start_link(),

	start_mqtt_listener(mqtt_port, Settings),
	start_mqtts_listener(mqtts_port, Settings),
	start_websocket_listener(http_port, Settings),

	{ok, Pid}.

stop(_State) ->
	timer:apply_after(0, application, stop, [ranch]).

