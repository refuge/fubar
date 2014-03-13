%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar session test cases.
%%%
%%% Created : Jan 23, 2014
%%% -------------------------------------------------------------------
-module(fubar_session_test).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile(export_all).
-include_lib("common_test/include/ct.hrl").

-define(WAIT, 1000).

offline_message(Config) ->
	Config1 = fubar_mqtt_test:mqtt_connect(Config, connected),
	case proplists:get_value(clients, Config1, []) of
		C when C > 1 ->
			C1 = <<"000000">>,
			C2 = <<"000001">>,
			mqtt_client_sup:stop_child(C2),
			ct:log("client ~p terminating", [C2]),
			% Wait a short while for termination.
			ct:sleep(?WAIT),
			mqtt_client:send(C1, mqtt:publish([{topic, C2}, {payload, C1}])),
			ct:log("client ~p sending ~p to ~p", [C1, C1, C2]),
			% Wait a short while for offline messaging.
			ct:sleep(?WAIT),
			mqtt_client_sup:restart_child(C2),
			ct:log("client ~p restarting", [C2]),
			% Wait a short while for message delivery.
			ct:sleep(?WAIT),
			C1 = mqtt_client:last_message(C2),
			ct:log("client ~p received ~p", [C2, C1]),
			fubar_mqtt_test:mqtt_disconnect(Config1, disconnected),
			ct:comment("Confirmed offline messaging from ~p to ~p", [C1, C2]);
		_ ->
			fubar_mqtt_test:mqtt_disconnect(Config1, disconnected),
			{skip, "There must be 2 clients at least"}
	end.

migration(Config) ->
	case proplists:get_value(servers, Config) of
		[{N1, _P1}, {N2, P2} | _] ->
			Config1 = fubar_mqtt_test:mqtt_connect(Config, connected),
			C1 = <<"000000">>,
			mqtt_client_sup:stop_child(C1),
			ct:log("client ~p terminating", [C1]),
			% Wait a short while for termination.
			ct:sleep(?WAIT),
			% Connect to a different server.
			mqtt_client:start([{client_id, C1}, {port, P2}]),
			ct:log("client ~p connecting to ~p", [C1, P2]),
			% Wait a short while for connection.
			ct:sleep(?WAIT),
			connected = mqtt_client:state(C1),
			{ok, {Pid, _, _}} = rpc:call(N2, fubar_route, resolve, [C1]),
			% The session must be in N2.
			N2 = node(Pid),
			fubar_mqtt_test:mqtt_disconnect(Config1, disconnected),
			ct:comment("Confirmed session migration from ~p to ~p", [N1, N2]);
		_ ->
			{skip, "There must be 2 servers at least"}
	end.
