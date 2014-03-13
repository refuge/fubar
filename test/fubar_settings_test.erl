%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Runtime settings test cases.
%%%
%%% Created : Jan 22, 2014
%%% -------------------------------------------------------------------
-module(fubar_settings_test).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile(export_all).
-include_lib("common_test/include/ct.hrl").

fubar_sysmon(Config) ->
	Servers = proplists:get_value(servers, Config),
	lists:foreach(
		fun({Node, _}) ->
			% Test changing high_watermark
			H = rpc:call(Node, fubar_sysmon, high_watermark, []),
			ok = rpc:call(Node, fubar, settings, [fubar_sysmon, {high_watermark, 0.1}]),
			0.1 = rpc:call(Node, fubar_sysmon, high_watermark, []),
			ok = rpc:call(Node, fubar, settings, [fubar_sysmon, {high_watermark, H}]),
			% Test changing interval
			I = rpc:call(Node, fubar_sysmon, interval, []),
			ok = rpc:call(Node, fubar, settings, [fubar_sysmon, {interval, 100}]),
			100 = rpc:call(Node, fubar_sysmon, interval, []),
			ok = rpc:call(Node, fubar, settings, [fubar_sysmon, {interval, I}]),
			% Test changing offloading_threshold
			T = rpc:call(Node, fubar_sysmon, offloading_threshold, []),
			ok = rpc:call(Node, fubar, settings, [fubar_sysmon, {offloading_threshold, 0.8}]),
			0.8 = rpc:call(Node, fubar_sysmon, offloading_threshold, []),
			ok = rpc:call(Node, fubar, settings, [fubar_sysmon, {offloading_threshold, T}])
		end,
		Servers),
	Config.

mqtt_server(Config) ->
	Servers = proplists:get_value(servers, Config),
	lists:foreach(
		fun({Node, _}) ->
			% Test changing address
			A = rpc:call(Node, mqtt_server, get_address, []),
			ok = rpc:call(Node, fubar, settings, [mqtt_server, {address, "test"}]),
			"test" = rpc:call(Node, mqtt_server, get_address, []),
			ok = rpc:call(Node, fubar, settings, [mqtt_server, {address, A}])
		end,
		Servers),
	Config.
