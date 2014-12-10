%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Generic MQTT client behavior.
%%%
%%% Created : Nov 15, 2012
%%% -------------------------------------------------------------------
-module(mqtt_client).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(mqtt_protocol).

%%
%% Helper interfaces.
%%
-export([
	connect/1, reconnect/1, disconnect/1, stop/1,
	send/2, state/1,
	start_link/1 % For mqtt_client_sup
]).

%%
%% mqtt_protocol behavior callbacks.
%%
-export([init/1, handle_message/2, handle_event/2, terminate/2]).

%%
%% Imports and definitions.
%%
-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

-define(STATE, ?MODULE).

%% @doc mqtt_protocol STATE
-record(?STATE, {
		handler :: module(),
		handler_state :: any(),
		client_id :: binary(),
		will :: {binary(), binary(), mqtt_qos(), boolean()},
		clean_session = false :: boolean(),
		timeout = 30000 :: timeout(),
		timestamp :: timestamp(),
		timer :: reference(),
		state = connecting :: connecting | connected | disconnecting,
		message_id = 0 :: integer(),
		retry_pool = [] :: [{integer(), mqtt_message(), integer(), Timer :: reference()}],
		max_retries = 3 :: integer(),
		retry_after = 30000 :: timeout(),
		wait_buffer = [] :: [{integer(), mqtt_message()}],
		max_waits = 10 :: integer()
}).

%%
%% mqtt_client behavior specifications.
%%
-callback handle_connected(State :: any()) ->
		NewState :: any().

-callback handle_disconnected(State :: any()) ->
		any().

-callback handle_message(mqtt_message(), State :: any()) ->
		NewState :: any().

-callback handle_event(Event :: any(), State :: any()) ->
		NewState :: any().

%% @doc Connect an MQTT client.
%% @param Params a property list with,
%% 		host = "localhost" :: string()
%% 		port = 1883 :: integer()
%% 		username = <<>> :: binary()
%% 		password = <<>> :: binary()
%% 		client_id = <<>> :: binary()
%% 		keep_alive = 600 :: integer() % in seconds
%% 		will_topic :: binary()
%% 		will_message :: binary()
%% 		will_qos = at_most_once :: mqtt_qos()
%% 		will_retail = false :: boolean()
%% 		clean_session = false :: boolean()
%% 		transport = ranch_tcp :: ranch_tcp | ranch_ssl
%% 		socket_options = [] :: proplists()
%% 		max_retries = 3 :: integer()
%% 		retry_after = 30000 :: integer() % in milliseconds
%% 		max_waits = 10 :: integer()
-spec connect(params()) -> {ok, pid()} | {error, reason()}.
connect(Params) ->
	mqtt_client_sup:connect(?MODULE, Params).

%% @doc Reconnect an MQTT client.
-spec reconnect(Id :: binary()) -> ok | {error, reason()}.
reconnect(Id) ->
	mqtt_client_sup:reconnect(Id).

%% @doc Disconnect an MQTT client.
-spec disconnect(binary() | [binary()]) -> ok.
disconnect(Ids) when erlang:is_list(Ids) ->
	lists:foreach(fun ?MODULE:disconnect/1, Ids);
disconnect(Id) ->
	mqtt_client_sup:disconnect(Id).

%% @doc Stop an MQTT client without disconnect.
-spec stop(binary() | [binary()]) -> ok.
stop(Ids) when erlang:is_list(Ids) ->
	lists:foreach(fun ?MODULE:stop/1, Ids);
stop(Id) ->
	mqtt_client_sup:stop(Id).

%% @doc Send an MQTT message.
-spec send(pid() | binary(), mqtt_message()) -> ok | {error, reason()}.
send(Pid, Message) when erlang:is_pid(Pid) ->
	Pid ! Message,
	ok;
send(Id, Message) ->
	case mqtt_client_sup:get(Id) of
		{ok, disconnected} -> {error, disconnected};
		{ok, Pid} -> send(Pid, Message);
		Error -> Error
	end.

%% @doc Get an MQTT client state.
-spec state(pid() | binary()) -> {ok, #?STATE{}} | {error, reason()}.
state(Client) ->
	case send(Client, {state, self()}) of
		ok ->
			receive
				State -> {ok, State}
			after 5000 -> {error, timeout}
			end;
		{error, disconnected} ->
			{ok, disconnected};
		Error ->
			Error
	end.

%% @doc Starter function for mqtt_client_sup.
-spec start_link(params()) -> {ok, pid()} | {error, reason()}.
start_link(Params) ->
	Params1 = Params ++ fubar:settings(?MODULE),
	case mqtt_protocol:start([{dispatch, ?MODULE} | proplists:delete(client_id, Params1)]) of
		{ok, Pid} ->
			link(Pid),
			send(Pid, mqtt:connect(Params1)),
			{ok, Pid};
		Error ->
			Error
	end.

%%
%% mqtt_protocol behavior implementations.
%%
-spec init(params()) -> {noreply, #?STATE{}, timeout()}.
init(Params) ->
	State = ?PROPS_TO_RECORD(Params, ?STATE),
	% Set timestamp as os:timestamp() and timeout to reset next ping schedule.
	{noreply, State#?STATE{timestamp=os:timestamp()}, State#?STATE.timeout}.

-spec handle_message(mqtt_message(), #?STATE{}) ->
		  {reply, mqtt_message(), #?STATE{}, timeout()} |
		  {noreply, #?STATE{}, timeout()} |
		  {stop, reason(), #?STATE{}}.
handle_message(Message, State=#?STATE{client_id=undefined}) ->
	% Drop messages from the server before CONNECT.
	% Ping schedule can be reset because we got a packet anyways.
	lager:warning("dropping message ~p before connect", [Message]),
	{noreply, State#?STATE{timestamp=os:timestamp()}, State#?STATE.timeout};
handle_message(Message=#mqtt_connack{code=Code},
		State=#?STATE{client_id=ClientId, state=connecting, handler=Handler}) ->
	% Received connack while waiting for one.
	case Code of
		accepted ->
			lager:debug("~p connection granted", [ClientId]),
			HandlerState = Handler:handle_connected(State#?STATE.handler_state),
			{noreply, State#?STATE{state=connected, handler_state=HandlerState, timestamp=os:timestamp()},
					State#?STATE.timeout};
		alt_server ->
			lager:debug("~p connection offloaded to ~p", [ClientId, Message#mqtt_connack.alt_server]),
			[T, HP] = binary:split(Message#mqtt_connack.alt_server, [<<"://">>]),
			[H, P] = binary:split(HP, [<<":">>]),
			{Transport, Host, Port} = {case T of
										   <<"tcp">> -> ranch_tcp;
										   <<"ssl">> -> ranch_ssl
									   end, binary:bin_to_list(H),
									   case string:to_integer(binary:bin_to_list(P)) of
									   	   {error, _} -> 1883;
									   	   {Int, _} -> Int
									   end},
			% Update global settings with the alt_server info.
			fubar:settings(?MODULE, [{transport, Transport}, {host, Host}, {port, Port}]),
			{stop, offloaded, State};
		_ ->
			lager:debug("~p connection rejected with ~p", [ClientId, Code]),
			Handler:handle_disconnected(State#?STATE.handler_state),
			{stop, normal, State}
	end;
handle_message(Message, State=#?STATE{client_id=ClientId, state=connecting}) ->
	% Drop messages from the server before CONNACK.
	lager:warning("~p dropping ~p, before connack", [ClientId, Message]),
	{noreply, State#?STATE{timestamp=os:timestamp()}, State#?STATE.timeout};
handle_message(Message, State=#?STATE{client_id=ClientId, state=disconnecting}) ->
	% Drop messages after DISCONNECT.
	lager:warning("~p dropping ~p, disconnecting", [ClientId, Message]),
	{noreply, State#?STATE{timestamp=os:timestamp(), timeout=0}, 0};
handle_message(#mqtt_pingresp{}, State=#?STATE{}) ->
	% Cancel expiration schedule if there is one.
	timer:cancel(State#?STATE.timer),
	{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout};
handle_message(Message=#mqtt_suback{message_id=MessageId}, State=#?STATE{client_id=ClientId}) ->
	timer:cancel(State#?STATE.timer),
	% Subscribe complete.  Stop retrying.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				State#?STATE.timeout};
		_ ->
			lager:warning("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}
	end;
handle_message(Message=#mqtt_unsuback{message_id=MessageId}, State=#?STATE{client_id=ClientId}) ->
	timer:cancel(State#?STATE.timer),
	% Unsubscribe complete.  Stop retrying.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				State#?STATE.timeout};
		_ ->
			lager:warning("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}
	end;
handle_message(Message=#mqtt_publish{message_id=MessageId},
		State=#?STATE{handler=Handler}) ->
	timer:cancel(State#?STATE.timer),
	% This is the very point to print a message received.
	case Message#mqtt_publish.qos of
		exactly_once ->
			% Transaction via 3-way handshake.
			Reply = #mqtt_pubrec{message_id=MessageId},
			case Message#mqtt_publish.dup of
				true ->
					case lists:keyfind(MessageId, 1, State#?STATE.wait_buffer) of
						false ->
							% Not likely but may have missed original.
							Buffer = lists:sublist([{MessageId, Message} | State#?STATE.wait_buffer],
										State#?STATE.max_waits),
							{reply, Reply, State#?STATE{timer=undefined, timestamp=os:timestamp(), wait_buffer=Buffer},
								State#?STATE.timeout};
						{MessageId, _} ->
							{reply, Reply, State#?STATE{timer=undefined, timestamp=os:timestamp()},
								State#?STATE.timeout}
					end;
				_ ->
					Buffer = lists:sublist([{MessageId, Message} | State#?STATE.wait_buffer],
								State#?STATE.max_waits),
					{reply, Reply, State#?STATE{timer=undefined, timestamp=os:timestamp(), wait_buffer=Buffer},
						State#?STATE.timeout}
			end;
		at_least_once ->
			% Transaction via 1-way handshake.
			HandlerState = Handler:handle_message(Message, State#?STATE.handler_state),
			{reply, #mqtt_puback{message_id=MessageId},
				State#?STATE{handler_state=HandlerState, timer=undefined, timestamp=os:timestamp()},
				State#?STATE.timeout};
		_ ->
			HandlerState = Handler:handle_message(Message, State#?STATE.handler_state),
			{noreply, State#?STATE{handler_state=HandlerState, timer=undefined, timestamp=os:timestamp()},
					State#?STATE.timeout}
	end;
handle_message(Message=#mqtt_puback{message_id=MessageId}, State=#?STATE{client_id=ClientId}) ->
	timer:cancel(State#?STATE.timer),
	% Complete a 1-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				State#?STATE.timeout};
		_ ->
			lager:warning("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}
	end;
handle_message(Message=#mqtt_pubrec{message_id=MessageId}, State=#?STATE{client_id=ClientId}) ->
	timer:cancel(State#?STATE.timer),
	% Commit a 3-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			Reply = #mqtt_pubrel{message_id=MessageId},
			{ok, NewTimer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Request, State#?STATE.max_retries, NewTimer} | Rest],
			{reply, Reply, State#?STATE{timer=undefined, timestamp=os:timestamp(), retry_pool=Pool},
				State#?STATE.timeout};
		_ ->
			lager:warning("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}
	end;
handle_message(Message=#mqtt_pubrel{message_id=MessageId},
		State=#?STATE{client_id=ClientId, handler=Handler}) ->
	timer:cancel(State#?STATE.timer),
	% Complete a server-driven 3-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?STATE.wait_buffer) of
		{value, {MessageId, Request}, Rest} ->
			HandlerState = Handler:handle_message(Request, State#?STATE.handler_state),
			Reply = #mqtt_pubcomp{message_id=MessageId},
			{reply, Reply, State#?STATE{handler_state=HandlerState, timer=undefined, timestamp=os:timestamp(), wait_buffer=Rest},
				State#?STATE.timeout};
		_ ->
			lager:warning("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}
	end;
handle_message(Message=#mqtt_pubcomp{message_id=MessageId}, State=#?STATE{client_id=ClientId}) ->
	timer:cancel(State#?STATE.timer),
	% Complete a 3-way handshake transaction.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				State#?STATE.timeout};
		_ ->
			lager:warning("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}
	end;
handle_message(Message, State) ->
	timer:cancel(State#?STATE.timer),
	% Drop unknown messages from the server.
	lager:warning("~p dropping unknown ~p", [State#?STATE.client_id, Message]),
	{noreply, State#?STATE{timer=undefined, timestamp=os:timestamp()}, State#?STATE.timeout}.

-spec handle_event(Event :: term(), #?STATE{}) ->
		  {reply, mqtt_message(), #?STATE{}, timeout()} |
		  {noreply, #?STATE{}, timeout()} |
		  {stop, term(), #?STATE{}}.
handle_event({state, From}, State) ->
	From ! State#?STATE.state,
	{noreply, State, timeout(State#?STATE.timeout, State#?STATE.timestamp)};
handle_event(timeout, State=#?STATE{client_id=undefined, handler=Handler}) ->
	lager:error("impossible overload timeout"),
	Handler:handle_disconnected(State#?STATE.handler_state),
	{stop, normal, State};
handle_event(timeout, State=#?STATE{client_id=ClientId, state=connecting}) ->
	lager:warning("~p connect timed out", [ClientId]),
	{stop, no_connack, State};
handle_event(timeout, State=#?STATE{state=disconnecting, handler=Handler}) ->
	Handler:handle_disconnected(State#?STATE.handler_state),
	{stop, normal, State};
handle_event(timeout, State) ->
	{ok, Timer} = timer:send_after(State#?STATE.retry_after, no_pingresp),
	{reply, #mqtt_pingreq{}, State#?STATE{timestamp=os:timestamp(), timer=Timer}, State#?STATE.timeout};
handle_event(Event=#mqtt_connect{}, State=#?STATE{client_id=undefined}) ->
	lager:debug("~p connecting", [Event#mqtt_connect.client_id]),
	{reply, Event, State#?STATE{
						client_id=Event#mqtt_connect.client_id,
						will=case Event#mqtt_connect.will_topic of
								undefined -> undefined;
								Topic -> {Topic, Event#mqtt_connect.will_message,
											Event#mqtt_connect.will_qos, Event#mqtt_connect.will_retain}
							 end,
						clean_session=Event#mqtt_connect.clean_session,
						timeout=case Event#mqtt_connect.keep_alive of
									infinity -> infinity;
									KeepAlive -> KeepAlive*1000
								end,
						timestamp=os:timestamp(),
						state=connecting}, State#?STATE.timeout};
handle_event(Event=#mqtt_subscribe{}, State) ->
	case Event#mqtt_subscribe.qos of
		at_most_once ->
			% This is out of spec. but trying.  Why not?
			{reply, Event, State#?STATE{timestamp=os:timestamp()},
				timeout(State#?STATE.timeout, State#?STATE.timestamp)};
		_ ->
			timer:cancel(State#?STATE.timer),
			MessageId = State#?STATE.message_id rem 16#ffff + 1,
			Message = Event#mqtt_subscribe{message_id=MessageId, qos=at_least_once},
			Dup = Message#mqtt_subscribe{dup=true},
			{ok, Timer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | State#?STATE.retry_pool],
			{reply, Message,
			 State#?STATE{timer=undefined, timestamp=os:timestamp(), message_id=MessageId, retry_pool=Pool},
			 State#?STATE.timeout}
	end;
handle_event(Event=#mqtt_unsubscribe{}, State) ->
	timer:cancel(State#?STATE.timer),
	case Event#mqtt_unsubscribe.qos of
		at_most_once ->
			% This is out of spec. but trying.  Why not?
			{reply, Event, State#?STATE{timestamp=os:timestamp()},
				timeout(State#?STATE.timeout, State#?STATE.timestamp)};
		_ ->
			timer:cancel(State#?STATE.timer),
			MessageId = State#?STATE.message_id rem 16#ffff + 1,
			Message = Event#mqtt_unsubscribe{message_id=MessageId, qos=at_least_once},
			Dup = Message#mqtt_unsubscribe{dup=true},
			{ok, Timer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | State#?STATE.retry_pool],
			{reply, Message,
			 State#?STATE{timer=undefined, timestamp=os:timestamp(), message_id=MessageId, retry_pool=Pool},
			 State#?STATE.timeout}
	end;
handle_event(Event=#mqtt_publish{}, State) ->
	case Event#mqtt_publish.qos of
		at_most_once ->
			{reply, Event, State#?STATE{timestamp=os:timestamp()},
				timeout(State#?STATE.timeout, State#?STATE.timestamp)};
		_ ->
			timer:cancel(State#?STATE.timer),
			MessageId = State#?STATE.message_id rem 16#ffff + 1,
			Message = Event#mqtt_publish{message_id=MessageId},
			Dup = Message#mqtt_publish{dup=true},
			{ok, Timer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | State#?STATE.retry_pool],
			{reply, Message,
			 State#?STATE{timer=undefined, timestamp=os:timestamp(), message_id=MessageId, retry_pool=Pool},
			 State#?STATE.timeout}
	end;
handle_event(Event=#mqtt_disconnect{}, State) ->
	timer:cancel(State#?STATE.timer),
	{reply, Event, State#?STATE{timer=undefined, state=disconnecting, timestamp=os:timestamp(), timeout=0}, 0};

handle_event({retry, MessageId}, State=#?STATE{client_id=ClientId}) ->
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, Message, Retry, _}, Rest} ->
			case Retry < State#?STATE.max_retries of
				true ->
					{ok, Timer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
					Pool = [{MessageId, Message, Retry+1, Timer} | Rest],
					{reply, Message, State#?STATE{timestamp=os:timestamp(), retry_pool=Pool},
						State#?STATE.timeout};
				_ ->
					lager:warning("~p dropping event ~p after retry", [ClientId, Message]),
					{noreply, State#?STATE{retry_pool=Rest},
						timeout(State#?STATE.timeout, State#?STATE.timestamp)}
			end;
		_ ->
			lager:error("~p no such retry ~p", [ClientId, MessageId]),
			{noreply, State, timeout(State#?STATE.timeout, State#?STATE.timestamp)}
	end;
handle_event(Event, State=#?STATE{client_id=ClientId, state=connecting}) ->
	lager:warning("~p dropping event ~p before connack", [ClientId, Event]),
	{noreply, State, timeout(State#?STATE.timeout, State#?STATE.timestamp)};
handle_event(no_pingresp, State=#?STATE{client_id=ClientId}) ->
	lager:info("~p connection lost", [ClientId]),
	{stop, no_pingresp, State};
handle_event(Event, State=#?STATE{handler=Handler}) ->
	HandlerState = Handler:handle_event(Event, State#?STATE.handler_state),
	{noreply, State#?STATE{handler_state=HandlerState}, timeout(State#?STATE.timeout, State#?STATE.timestamp)}.

%% @doc Finalize the client process.
-spec terminate(term(), #?STATE{}) -> term().
terminate(normal, State=#?STATE{state=disconnecting, handler=Handler}) ->
	Handler:handle_disconnected(State#?STATE.handler_state),
	normal;
terminate(Reason, State=#?STATE{handler=Handler}) ->
	Handler:handle_disconnected(State#?STATE.handler_state),
	Reason.

%%
%% Local Functions
%%
timeout(infinity, _) ->
	infinity;
timeout(Milliseconds, Timestamp) ->
	Elapsed = timer:now_diff(os:timestamp(), Timestamp) div 1000,
	case Milliseconds > Elapsed of
		true -> Milliseconds - Elapsed;
		_ -> 0
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
