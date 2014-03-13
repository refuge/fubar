%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar hook for common test suite
%%%   This module prepares fubar server nodes for the tests.
%%%
%%% Created : Jan 21, 2014
%%% -------------------------------------------------------------------
-module(fubar_HOOK).
-author("Sungjin Park <jinni.park@gmail.com>").

-compile(export_all).
-include_lib("common_test/include/ct.hrl").

-define(STATE, ?MODULE).

-record(?STATE, {
	cookie = ?MODULE,
	servers = [
		{fubar_test_server_1, 1883},
		{fubar_test_server_2, 1884}
	]
}).

init(_, _) ->
	{ok, #?STATE{}}.

pre_init_per_suite(_Suite, Config, State=#?STATE{cookie=Cookie}) ->
	erlang:set_cookie(node(), Cookie),
	[Host | _] = string:tokens(os:cmd("hostname -s"), "\r\n"),
	{Servers, _} =
		lists:mapfoldl(
			fun
				({Name, Port}, undefined) ->
					% This is the first node.
					% Start in standalone mode.
					ct:log(os:cmd(io_lib:format(
						"cd ../..; make run node=~s mqtt_port=~B cookie=~s",
						[Name, Port, Cookie]))),
					Node = erlang:list_to_atom(
							lists:flatten(io_lib:format("~s@~s", [Name, Host]))),
					wait_for_application(Node, fubar),
					rpc:call(Node, mqtt_server, set_address,
						[io_lib:format("tcp://127.0.0.1:~B", [Port])]),
					{{Node, Port}, Node};
				({Name, Port}, Master) ->
					% This is not the first node.
					% Start in cluster mode.
					ct:log(os:cmd(io_lib:format(
						"cd ../..; make run node=~s mqtt_port=~B cookie=~s master=~s",
						[Name, Port, Cookie, Master]))),
					Node = erlang:list_to_atom(
							lists:flatten(io_lib:format("~s@~s", [Name, Host]))),
					wait_for_application(Node, fubar),
					rpc:call(Node, mqtt_server, set_address,
						[io_lib:format("tcp://127.0.0.1:~B", [Port])]),
					{{Node, Port}, Node}

			end,
			undefined,
			State#?STATE.servers),
	{Nodes, _} = lists:unzip(Servers),
	wait_for_nodes(lists:sort(Nodes)),
	{[{cookie, Cookie}, {servers, Servers} | Config], State}.

wait_for_application(Node, App) ->
	case rpc:call(Node, application, which_applications, []) of
		{badrpc, _} ->
			ct:sleep(3000),
			wait_for_application(Node, App);
		Apps ->
			case lists:keyfind(App, 1, Apps) of
				false ->
					ct:sleep(3000),
					wait_for_application(Node, App);
				_ ->
					ok
			end
	end.

wait_for_nodes(Nodes) ->
	case lists:sort(nodes()) of
		Nodes ->
			ok;
		_ ->
			ct:sleep(3000),
			wait_for_nodes(Nodes)
	end.

post_init_per_suite(_Suite, _Config, Return, State) ->
	{Return, State}.

pre_end_per_suite(_Suite, Config, State) ->
	{Config, State}.

post_end_per_suite(_Suite, _Config, Return, State=#?STATE{cookie=Cookie}) ->
	lists:foreach(
		fun({Name, _}) ->
			ct:log(os:cmd(io_lib:format("cd ../..; make stop node=~s cookie=~s", [Name, Cookie]))),
			ct:log(os:cmd(io_lib:format("cd ../..; make reset node=~s", [Name])))
		end,
		State#?STATE.servers),
	{Return, State}.

terminate(_State) ->
	ok.
