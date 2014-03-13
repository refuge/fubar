%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar common test suite
%%%
%%% Created : Jan 20, 2014
%%% -------------------------------------------------------------------
-module(fubar_SUITE).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile(export_all).
-include_lib("common_test/include/ct.hrl").

suite() ->
	[{timetrap, {minutes, 1}},
	 {ct_hooks, [fubar_HOOK]}].

all() ->
	[{group, fubar_settings_test},
	 {group, fubar_mqtt_test},
	 {group, fubar_session_test},
	 {group, fubar_cluster_test}].

groups() ->
	[{fubar_settings_test, [parallel, shuffle],
		[fubar_settings_test_fubar_sysmon,
		 fubar_settings_test_mqtt_server]},
	 {fubar_mqtt_test, [sequence],
	 	[fubar_mqtt_test_mqtt_connect,
	 	 fubar_mqtt_test_mqtt_pubsub,
	 	 fubar_mqtt_test_mqtt_direct]},
	 {fubar_session_test, [sequence],
	 	[fubar_session_test_offline_message,
	 	 fubar_session_test_migration]},
	 {fubar_cluster_test, [sequence],
	 	[fubar_cluster_test_load_balancing]}].

fubar_settings_test_fubar_sysmon(Config) ->
	fubar_settings_test:fubar_sysmon(Config),
	ct:comment("Verified runtime sysmon settings").

fubar_settings_test_mqtt_server(Config) ->
	fubar_settings_test:mqtt_server(Config),
	ct:comment("Verified runtime server settings").

fubar_mqtt_test_mqtt_connect(Config) ->
	mqtt_client_sup:start_link(),
	Servers = proplists:get_value(servers, Config),
	Config1 = [{username, <<"test">>}, {password, <<"test">>} | Config],
	% Connect must fail without valid account
	fubar_mqtt_test:mqtt_connect(Config1, disconnected),
	lists:foreach(
		fun({Node, _}) ->
			ok = rpc:call(Node, mqtt_acl, update, [{127,0,0,1}, true])
		end,
		Servers),
	% Connect must succeed with acl pass
	Config2 = fubar_mqtt_test:mqtt_connect(Config1, connected),
	Config3 = fubar_mqtt_test:mqtt_disconnect(Config2, disconnected),
	lists:foreach(
		fun({Node, _}) ->
			ok = rpc:call(Node, mqtt_account, update, [<<"test">>, <<"test">>]),
			ok = rpc:call(Node, mqtt_acl, update, [{127,0,0,1}, false])
		end,
		Servers),
	% Connect must fail with acl block even with valid account
	fubar_mqtt_test:mqtt_connect(Config3, disconnected),
	lists:foreach(
		fun({Node, _}) ->
			ok = rpc:call(Node, mqtt_acl, delete, [{127,0,0,1}])
		end,
		Servers),
	% Connect must succeed with valid account and without acl block
	Config4 = fubar_mqtt_test:mqtt_connect(Config3, connected),
	fubar_mqtt_test:mqtt_disconnect(Config4, disconnected),
	lists:foreach(
		fun({Node, _}) ->
			ok = rpc:call(Node, mqtt_account, delete, [<<"test">>])
		end,
		Servers),
	mqtt_client_sup:stop(),
	ct:comment("Verified ACL pass/block and account control").

fubar_mqtt_test_mqtt_pubsub(Config) ->
	prepare_client_sup(Config),
	fubar_mqtt_test:mqtt_pubsub([{topic, <<"test_topic">>} | Config]),
	unprepare_client_sup(Config),
	ct:comment("Verified MQTT pubsub logic").

fubar_mqtt_test_mqtt_direct(Config) ->
	prepare_client_sup(Config),
	fubar_mqtt_test:mqtt_direct(Config),
	unprepare_client_sup(Config),
	ct:comment("Verified MQTT direct messaging logic").

fubar_session_test_offline_message(Config) ->
	prepare_client_sup(Config),
	Result = fubar_session_test:offline_message(Config),
	unprepare_client_sup(Config),
	Result.

fubar_session_test_migration(Config) ->
	prepare_client_sup(Config),
	Result = fubar_session_test:migration(Config),
	unprepare_client_sup(Config),
	Result.

fubar_cluster_test_load_balancing(Config) ->
	prepare_client_sup(Config),
	Result = fubar_cluster_test:load_balancing(Config),
	unprepare_client_sup(Config),
	Result.

prepare_client_sup(Config) ->
	mqtt_client_sup:start_link(),
	lists:foreach(
		fun({Node, _}) ->
			ok = rpc:call(Node, mqtt_acl, update, [{127,0,0,1}, true])
		end,
		proplists:get_value(servers, Config)).

unprepare_client_sup(Config) ->
	lists:foreach(
		fun({Node, _}) ->
			ok = rpc:call(Node, mqtt_acl, delete, [{127,0,0,1}])
		end,
		proplists:get_value(servers, Config)),
	mqtt_client_sup:stop().
