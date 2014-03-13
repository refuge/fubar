%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar event handler callback.
%%%
%%% Created : Jan 17, 2014
%%% -------------------------------------------------------------------
-module(fubar_event).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(gen_event).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

init(_) ->
	lager:notice("system event handler init"),
	{ok, undefined}.

handle_event({set_alarm, {{fubar_sysmon, global}, {offloading_to, Node}}}, State) when Node =/= node() ->
	fubar:settings(mqtt_server, {load_balancing, Node}),
	{ok, State};
handle_event({clear_alarm, {fubar_sysmon, global}}, State) ->
	fubar:settings(mqtt_server, {load_balancing, none}),
	{ok, State};
handle_event({set_alarm, {{fubar_sysmon, Node}, overloaded}}, State) when Node =:= node() ->
	fubar:settings(mqtt_server, {overloaded, true}),
	{ok, State};
handle_event({clear_alarm, {fubar_sysmon, Node}}, State) when Node =:= node() ->
	fubar:settings(mqtt_server, {overloaded, false}),
	{ok, State};
handle_event(Event, State) ->
	lager:debug("unknown event ~p", [Event]),
	{ok, State}.

handle_call(Call, State) ->
	lager:warning("unknown call ~p", [Call]),
	{ok, ok, State}.

handle_info(Info, State) ->
	lager:warning("unknown info ~p", [Info]),
	{ok, State}.

terminate(Reason, _State) ->
	lager:notice("system event handler terminate by ~p", [Reason]),
	normal.

code_change(_Version, State, _Extra) ->
	{ok, State}.
