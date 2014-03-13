%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar clustering test cases.
%%%
%%% Created : Jan 23, 2014
%%% -------------------------------------------------------------------
-module(fubar_cluster_test).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile(export_all).
-include_lib("common_test/include/ct.hrl").

-define(WAIT, 1000).

load_balancing(Config) ->
	% Set all the servers overloaded.
	Servers = proplists:get_value(servers, Config),
	ST = lists:map(
			fun({N, _P}) ->
				I0 = rpc:call(N, fubar_sysmon, interval, []),
				rpc:call(N, fubar_sysmon, interval, [?WAIT]),
				W0 = rpc:call(N, fubar_sysmon, high_watermark, []),
				L0 = rpc:call(N, fubar_sysmon, load, []),
				ct:log("Server ~p interval=~p, high_watermark=~p, load=~p", [N, I0, W0, L0]),
				rpc:call(N, fubar_sysmon, high_watermark, [W0*L0/1.2]),
				ct:log("Server ~p interval=~p, high_watermark=~p", [N, ?WAIT, W0*L0/1.2]),
				{I0, W0}
			end,
			Servers),
	% Wait a shor while for new settings to be applied.
	ct:sleep(?WAIT*3),
	% Check overloaded.
	lists:foreach(
		fun({N, _P}) ->
			true = proplists:get_value(overloaded,
					rpc:call(N, fubar, settings, [mqtt_server])),
			rpc:call(N, fubar, settings, [mqtt_server, {when_overloaded, drop}]),
			ct:log("Server ~p when_overloaded=~p", [N, drop])
		end,
		Servers),
	% Set default server as the first one.
	[{N1, P1}, {N2, P2} | _] = Servers,
	fubar:settings(mqtt_client, [{port, P1}, {max_recursion, 3}]),
	ct:log("Set default port=~p", [P1]),
	% Connect must fail now.
	C = <<"000000">>,
	mqtt_client:start([{client_id, C}]),
	ct:sleep(?WAIT),
	disconnected = mqtt_client:state(C),
	ct:log("Connection rejected"),
	% Unload server 2.
	L2 = rpc:call(N2, fubar_sysmon, load, []),
	W2 = rpc:call(N2, fubar_sysmon, high_watermark, []),
	rpc:call(N2, fubar_sysmon, high_watermark, [W2*L2/0.5]),
	ct:log("Server ~p high_watermark=~p", [N2, W2*L2/0.5]),
	ct:sleep(?WAIT*3),
	% Client must be offloaded to server 2 now.
	mqtt_client:start([{client_id, C}]),
	ct:sleep(?WAIT*2),
	P2 = proplists:get_value(port, fubar:settings(mqtt_client)),
	ct:log("Offloaded to ~p", [P2]),
	connected = mqtt_client:state(C),
	ct:log("Connection accepted"),
	{ok, {Pid2, _, _}} = rpc:call(N2, fubar_route, resolve, [C]),
	N2 = node(Pid2),
	ct:log("Session found in ~p", [N2]),
	mqtt_client:stop(C),
	% Unload server 1.
	L1 = rpc:call(N1, fubar_sysmon, load, []),
	W1 = rpc:call(N1, fubar_sysmon, high_watermark, []),
	rpc:call(N1, fubar_sysmon, high_watermark, [W1*L1/0.5]),
	ct:log("Server ~p high_watermark=~p", [N1, W1*L1/0.5]),
	ct:sleep(?WAIT*3),
	% Client must connect to server 1 again.
	fubar:settings(mqtt_client, {port, P1}),
	ct:log("Changed target port to ~p", [P1]),
	mqtt_client:start([{client_id, C}]),
	ct:sleep(?WAIT),
	connected = mqtt_client:state(C),
	ct:log("Connection accepted"),
	{ok, {Pid1, _, _}} = rpc:call(N1, fubar_route, resolve, [C]),
	N1 = node(Pid1),
	ct:log("Session found in ~p", [N1]),
	mqtt_client:stop(C),
	% Restore settings.
	lists:foreach(
		fun({{N, _P}, {I0, W0}}) ->
			rpc:call(N, fubar_sysmon, interval, [I0]),
			rpc:call(N, fubar_sysmon, high_watermark, [W0]),
			ct:log("Server ~p interval=~p, high_watermark=~p", [N, I0, W0])
		end,
		lists:zip(Servers, ST)),
	{comment, "Overloading and offloading scenarios complete"}.
