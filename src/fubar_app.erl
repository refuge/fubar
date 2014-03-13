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

%%
%% Records
%%
-record(?MODULE, {acceptors = 100 :: integer(),
				  max_connections = infinity :: timeout(),
				  options = []}).

%%
%% Application callbacks
%%
start(_StartType, _StartArgs) ->
	Settings = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),
	{ok, Pid} = fubar_sup:start_link(),
	case {string:to_integer(os:getenv("MQTT_PORT")), Settings#?MODULE.max_connections} of
		{{error, _}, _} ->
			ok;
		{{MQTTPort, _}, MQTTMax} ->
			ranch:start_listener(mqtt, Settings#?MODULE.acceptors,
								 ranch_tcp, [{port, MQTTPort}, {max_connections, MQTTMax} |
											 Settings#?MODULE.options],
								 mqtt_protocol, [{dispatch, mqtt_server}])
	end,
	case {string:to_integer(os:getenv("MQTTS_PORT")), Settings#?MODULE.max_connections} of
		{{error, _}, _} ->
			ok;
		{{MQTTSPort, _}, MQTTSMax} ->
			ranch:start_listener(mqtts, Settings#?MODULE.acceptors,
								 ranch_ssl, [{port, MQTTSPort}, {max_connections, MQTTSMax} |
											 Settings#?MODULE.options],
								 mqtt_protocol, [{dispatch, mqtt_server}])
	end,
	Dispatch = cowboy_router:compile([
		{'_', [
			{"/websocket", websocket_protocol, [{dispatch, mqtt_server}]}
		]}
	]),
	case {string:to_integer(os:getenv("HTTP_PORT")), Settings#?MODULE.max_connections} of
		{{error, _}, _} ->
			ok;
		{{HTTPPort, _}, HTTPMax} ->
			cowboy:start_http(http, Settings#?MODULE.acceptors,
							  [{port, HTTPPort}, {max_connections, HTTPMax} |
							   Settings#?MODULE.options],
							  [{env, [{dispatch, Dispatch}]}])
	end,
	{ok, Pid}.

stop(_State) ->
	timer:apply_after(0, application, stop, [ranch]).
