%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Websocket handler for fubar.
%%%
%%% Created : Sep 23, 2013
%%% -------------------------------------------------------------------
-module(websocket_protocol).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(cowboy_websocket_handler).

-export([init/3, websocket_init/3, websocket_handle/3, websocket_info/3, websocket_terminate/3]).

%%
%% Includes
%%
-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

%%
%% Records
%%
-record(?MODULE, {transport = ranch_tcp :: module(),
				  max_packet_size = 4096 :: pos_integer(),
				  header,
				  buffer = <<>> :: binary(),
				  dispatch :: module(),
				  context = [] :: any(),
				  timeout = 10000 :: timeout()}).

init(_Proto, _Req, _Props) ->
	{upgrade, protocol, cowboy_websocket}.

websocket_init(Transport, Req, Props) ->
	process_flag(trap_exit, true),
	lager:notice("websocket_init(~p)", [Transport]),
	Settings = fubar:settings(?MODULE),
	State = ?PROPS_TO_RECORD(Props ++ Settings, ?MODULE),
	Dispatch = State#?MODULE.dispatch,
	mqtt_stat:join(connections),
	case Dispatch:init(State#?MODULE.context) of
		{reply, Reply, NewContext, Timeout} ->
			Data = mqtt_protocol:format(Reply),
			lager:debug("STREAM OUT ~p", [Data]),
			{reply, {binary, Data}, Req, State#?MODULE{context=NewContext, timeout=Timeout}};
		{reply_later, Reply, NewContext, Timeout} ->
			self() ! {send, Reply},
			{ok, Req, State#?MODULE{context=NewContext, timeout=Timeout}};
		{noreply, NewContext, Timeout} ->
			{ok, Req, State#?MODULE{context=NewContext, timeout=Timeout}};
		{stop, Reason} ->
			lager:debug("dispatch init failure ~p", [Reason]),
			% Cowboy doesn't call websocket_terminate/3 in this case.
			websocket_terminate(Reason, Req, State),
			{shutdown, Req}
	end.

websocket_handle({binary, Data}, Req, State=#?MODULE{buffer=Buffer, dispatch=Dispatch, context=Context}) ->
	erlang:garbage_collect(),
	case Data of
		<<>> -> ok;
		_ -> lager:debug("STREAM IN ~p", [Data])
	end,
	% Append the packet at the end of the buffer and start parsing.
	case mqtt_protocol:parse(State#?MODULE{buffer= <<Buffer/binary, Data/binary>>}) of
		{ok, Message, NewState} ->
			% Parsed one message.
			% Call dispatcher.
			case Dispatch:handle_message(Message, Context) of
				{reply, Reply, NewContext, NewTimeout} ->
					Data1 = mqtt_protocol:format(Reply),
					lager:debug("STREAM OUT ~p", [Data1]),
					% Need to trigger next parsing schedule.
					self() ! {tcp, cowboy_req:get(socket, Req), <<>>},
					{reply, {binary, Data1}, Req, NewState#?MODULE{context=NewContext, timeout=NewTimeout}};
				{reply_later, Reply, NewContext, NewTimeout} ->
					self() ! {send, Reply},
					{ok, Req, NewState#?MODULE{context=NewContext, timeout=NewTimeout}};
				{noreply, NewContext, NewTimeout} ->
					{ok, Req, NewState#?MODULE{context=NewContext, timeout=NewTimeout}};
				{stop, Reason, NewContext} ->
					lager:debug("dispatch issued stop ~p", [Reason]),
					{shutdown, Req, NewState#?MODULE{context=NewContext}}
			end;
		{more, NewState} ->
			% The socket gets active after consuming previous data.
			{ok, Req, NewState};
		{error, Reason, NewState} ->
			lager:warning("parse error ~p", [Reason]),
			{shutdown, Req, NewState}
	end.

websocket_info({'EXIT', From, Reason}, Req, State=#?MODULE{dispatch=Dispatch, context=Context}) ->
	lager:warning("trap exit ~p from ~p", [Reason, From]),
	Dispatch:handle_error(undefined, Context),
	{shutdown, Req, State};
websocket_info({send, Reply}, Req, State) ->
	Data = mqtt_protocol:format(Reply),
	lager:debug("STREAM OUT: ~p", [Data]),
	{reply, {binary, Data}, Req, State};
websocket_info(Info, Req, State=#?MODULE{dispatch=Dispatch, context=Context}) ->
	case Dispatch:handle_event(Info, Context) of
		{reply, Reply, NewContext, NewTimeout} ->
			Data = mqtt_protocol:format(Reply),
			lager:debug("STREAM OUT ~p", [Data]),
			{reply, {binary, Data}, Req, State#?MODULE{context=NewContext, timeout=NewTimeout}};
		{reply_later, Reply, NewContext, NewTimeout} ->
			self() ! {send, Reply},
			{ok, Req, State#?MODULE{context=NewContext, timeout=NewTimeout}};
		{noreply, NewContext, NewTimeout} ->
			{ok, Req, State#?MODULE{context=NewContext, timeout=NewTimeout}};
		{stop, Reason, NewContext} ->
			lager:debug("dispatch issued stop ~p", [Reason]),
			{shutdown, Req, State#?MODULE{context=NewContext}}
	end.

websocket_terminate(Reason, _Req, #?MODULE{dispatch=Dispatch, context=Context}) ->
	lager:notice("websocket_terminate(~p)", [Reason]),
	mqtt_stat:leave(connections),
	Dispatch:terminate(Context),
	ok.
