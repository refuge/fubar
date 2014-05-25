%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT test cases.
%%%
%%% Created : Jan 22, 2014
%%% -------------------------------------------------------------------
-module(fubar_mqtt_test).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile(export_all).
-include_lib("common_test/include/ct.hrl").

-define(WAIT, 1000).

mqtt_connect(Config, State) ->
	Servers = proplists:get_value(servers, Config),
	Username = proplists:get_value(username, Config, <<>>),
	Password = proplists:get_value(password, Config, <<>>),
	% All the servers are supposed to run locally.
	Params = [{username, Username}, {password, Password}],
	Clients =
		lists:foldl(
			fun({_Node, Port}, N) ->
				% <<"000000">>, <<"000001">,...
				Id = erlang:list_to_binary(io_lib:format("~6..0B", [N])),
				% Clients must start ok.
				{ok, Pid} = mqtt_client_simple:connect([
							{client_id, Id}, {port, Port} | Params]),
				ct:log("client ~p connecting to ~p", [Id, Port]),
				% Wait a short while to make sure connected or rejected.
				ct:sleep(?WAIT),
				{ok, State} = mqtt_client:state(Id),
				N + 1
			end,
			0,
			Servers),
	[{clients, Clients} | Config].

mqtt_disconnect(Config, State) ->
	Ids = [erlang:list_to_binary(io_lib:format("~6..0B", [N])) ||
			N <- lists:seq(0, proplists:get_value(clients, Config)-1)],
	lists:foreach(
		fun(Id) ->
			ct:log("client ~p disconnecting", [Id]),
			mqtt_client:disconnect(Id),
			% Wait a short while to make sure disconnected.
			ct:sleep(?WAIT),
			{ok, State} = mqtt_client:state(Id)
		end,
		Ids),
	proplists:delete(clients, Config).

mqtt_pubsub(Config) ->
	Config1 = mqtt_connect(Config, connected),
	Topic = proplists:get_value(topic, Config1),
	Ids = [erlang:list_to_binary(io_lib:format("~6..0B", [N])) ||
			N <- lists:seq(0, proplists:get_value(clients, Config1)-1)],
	lists:foreach(
		fun(Id) ->
			ct:log("client ~p subscribing to ~p", [Id, Topic]),
			mqtt_client:send(Id, mqtt:subscribe([{topics, [Topic]}])),
			% Subscribe may fail due to server-side concurrency control.
			% Even so, it will succeed eventually by automatic retry.
			% Here we wait a short while to avoid collision.
			ct:sleep(?WAIT)
		end,
		Ids),
	lists:foreach(
		fun(Id) ->
			ct:log("client ~p publishing to ~p", [Id, Topic]),
			mqtt_client:send(Id, mqtt:publish([{topic, Topic}, {payload, Id}])),
			% Wait a short while for delivery.
			ct:sleep(?WAIT),
			lists:foreach(
				fun(Id1) ->
					{ok, Id} = mqtt_client_simple:last_message(Id1)
				end,
				Ids)
		end,
		Ids),
	lists:foreach(
		fun(Id) ->
			ct:log("client ~p unsubscribing from ~p", [Id, Topic]),
			mqtt_client:send(Id, mqtt:unsubscribe([{topics, [Topic]}]))
		end,
		Ids),
	mqtt_disconnect(Config1, disconnected).

mqtt_direct(Config) ->
	Config1 = mqtt_connect(Config, connected),
	Ids = [erlang:list_to_binary(io_lib:format("~6..0B", [N])) ||
			N <- lists:seq(0, proplists:get_value(clients, Config1)-1)],
	lists:foreach(
		fun(Id) ->
			lists:foreach(
				fun(Id1) ->
					ct:log("client ~p sending to ~p", [Id, Id1]),
					mqtt_client:send(Id, mqtt:publish([{topic, Id1}, {payload, Id}]))
				end,
				Ids),
			% Wait a short while for delivery.
			ct:sleep(?WAIT),
			lists:foreach(
				fun(Id1) ->
					{ok, Id} = mqtt_client_simple:last_message(Id1)
				end,
				Ids)
		end,
		Ids),
	mqtt_disconnect(Config1, disconnected).
