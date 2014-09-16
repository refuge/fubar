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

start_listener(EnvPort, Settings, Fun) ->
	{ok, Port} = application:get_env(?APPLICATION, EnvPort),
	MaxConnections = Settings#?MODULE.max_connections,
	Options = Settings#?MODULE.options,
	Acceptors = Settings#?MODULE.acceptors,

	case {Port, MaxConnections} of
		{undefined, _} -> no_port;
		_ ->
			case Fun(Port, Acceptors, MaxConnections, Options) of
				{error, _} -> error;
				Started -> Started
			end
	end.

mqtt_listener(Port, Acceptors, MaxConnections, Options) ->
	ranch:start_listener(
		mqtt,
		Acceptors,
		ranch_tcp,
		[{port, Port}, {max_connections, MaxConnections} | Options],
		mqtt_protocol,
		[{dispatch, mqtt_server}]
	).

mqtts_listener(Port, Acceptors, MaxConnections, Options) ->
	ranch:start_listener(
		mqtts,
		Acceptors,
		ranch_ssl,
		[{port, Port}, {max_connections, MaxConnections} | Options],
		mqtt_protocol,
		[{dispatch, mqtt_server}]
	).

http_listener(Port, Acceptors, MaxConnections, Options) ->
	Dispatch = cowboy_router:compile([
		{'_', [
			{"/mqtt", websocket_protocol, [{dispatch, mqtt_server}]},
			{"/[...]", cowboy_static, {priv_dir, fubar, ""}}
		]}
	]),

	cowboy:start_http(
		http,
		Acceptors,
		[{port, Port}, {max_connections, MaxConnections} | Options],
		[{env, [{dispatch, Dispatch}]}]
	).

%%
%% Application callbacks
%%
start(_StartType, _StartArgs) ->
	Settings = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),

	{ok, Pid} = fubar_sup:start_link(),

	start_listener(mqtt_port, Settings, fun mqtt_listener/4),
	start_listener(mqtts_port, Settings, fun mqtts_listener/4),
	start_listener(http_port, Settings, fun http_listener/4),

	{ok, Pid}.

stop(_State) ->
	timer:apply_after(0, application, stop, [ranch]).

