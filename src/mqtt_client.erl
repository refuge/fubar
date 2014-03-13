%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT tty client prints messages to error_logger.
%%%
%%% Created : Nov 15, 2012
%%% -------------------------------------------------------------------
-module(mqtt_client).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(mqtt_protocol).

%%
%% Exports
%%
-export([
	start/1, restart/1, stop/1, delete/1, start_link/1,
	send/2, last_message/1, state/1, context/1
]).

%% mqtt_protocol callbacks
-export([init/1, handle_message/2, handle_event/2, terminate/2]).

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

-define(CONTEXT, ?MODULE).

-type state() :: connecting | connected | disconnecting | disconnected.

%% @doc mqtt_protocol context
-record(?CONTEXT, {
		client_id :: binary(),
		will :: {binary(), binary(), mqtt_qos(), boolean()},
		clean_session = false :: boolean(),
		timeout = 30000 :: timeout(),
		timestamp :: timestamp(),
		timer :: Timer :: reference(),
		state = connecting :: state(),
		last_message :: binary(),
		message_id = 0 :: integer(),
		retry_pool = [] :: [{integer(), mqtt_message(), integer(), Timer :: reference()}],
		max_retries = 3 :: integer(),
		retry_after = 30000 :: timeout(),
		wait_buffer = [] :: [{integer(), mqtt_message()}],
		max_waits = 10 :: integer()
}).

-type context() :: #?CONTEXT{}.

%% @doc Start an MQTT client under mqtt_client_sup
%%      Parameters(defaults):
%%        host(localhost), port(1883), username(<<>>), password(<<>>),
%%        client_id(<<>>), keep_alive(600), will_topic(undefined),
%%        will_message(undefined), will_qos(at_most_once), will_retain(false),
%%        clean_session(false),
%%        transport(ranch_tcp), socket_options([])
-spec start(params) -> {ok, pid()} | {error, Reason :: term()}.
start(Props) ->
	mqtt_client_sup:start_child(?MODULE, Props).

%% @doc Restart a stopped client.
-spec restart(ClientId :: binary()) -> ok | {error, Reason :: term()}.
restart(Id) ->
	mqtt_client_sup:restart_child(Id).

%% @doc Stop an MQTT client.
-spec stop(pid() | binary() | [binary()]) -> ok.
stop(Client) when is_pid(Client) ->
	Client ! mqtt:disconnect([]);
stop(Ids) when is_list(Ids) ->
	lists:foreach(fun ?CONTEXT:stop/1, Ids);
stop(Id) ->
	[Client ! mqtt:disconnect([]) ||
	   {Cid, Client} <- mqtt_client_sup:connected(),
	   Cid =:= Id].

%% @doc Delete an MQTT client.
-spec delete(ClientId :: binary()) -> ok | {error, Reason :: term()}.
delete(Id) ->
	supervisor:delete_child(mqtt_client_sup, Id).

%% @doc Start and link an MQTT client in standalone mode.
-spec start_link(params()) -> {ok, pid()} | {error, Reason :: term()}.
start_link(Props) ->
	Props1 = Props ++ fubar:settings(?MODULE),
	case mqtt_protocol:start([{dispatch, ?MODULE} | proplists:delete(client_id, Props1)]) of
		{ok, Client} ->
			link(Client),
			Client ! mqtt:connect(Props1),
			{ok, Client};
		Error ->
			Error
	end.

%% @doc Send an MQTT message.
-spec send(pid() | binary(), mqtt_message()) -> ok | {error, Reason :: term()}.
send(Pid, Message) when erlang:is_pid(Pid) ->
	Pid ! Message;
send(Id, Message) ->
	case mqtt_client_sup:get(Id) of
		{error, Reason} -> Reason;
		Pid when erlang:is_pid(Pid) -> Pid ! Message
	end.

%% @doc Get the last message received.
-spec last_message(pid() | binary()) -> binary() | {error, Reason :: term()}.
last_message(Pid) when erlang:is_pid(Pid) ->
	Pid ! {last_message, self()},
	receive
		Message -> Message
		after 5000 -> {error, timeout}
	end;
last_message(Id) ->
	case mqtt_client_sup:get(Id) of
		{error, Reason} -> {error, Reason};
		Pid when erlang:is_pid(Pid) -> last_message(Pid)
	end.

%% @doc Get connection state of an MQTT client process.
-spec state(pid() | binary()) -> state() | {error, Reason :: term()}.
state(Pid) when erlang:is_pid(Pid) ->
	Pid ! {state, self()},
	receive
		State -> State
		after 5000 -> {error, timeout}
	end;
state(Id) ->
	case mqtt_client_sup:get(Id) of
		{error, Reason} -> {error, Reason};
		undefined -> disconnected;
		Pid when erlang:is_pid(Pid) -> state(Pid)
	end.

%% @doc Get internal context of an MQTT client process.
-spec context(pid() | binary()) -> context() | {error, Reason :: term()}.
context(Pid) when erlang:is_pid(Pid) ->
	Pid ! {context, self()},
	receive
		Context -> Context
		after 5000 -> {error, timeout}
	end;
context(Id) ->
	case mqtt_client_sup:get(Id) of
		{error, Reason} -> {error, Reason};
		Pid when erlang:is_pid(Pid) -> context(Pid)
	end.

-spec init(params()) -> {noreply, context(), timeout()}.
init(Props) ->
	Context = ?PROPS_TO_RECORD(Props, ?CONTEXT),
	% Setting timeout is default for ping.
	% Set timestamp as os:timestamp() and timeout to reset next ping schedule.
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout}.

-spec handle_message(mqtt_message(), context()) ->
		  {reply, mqtt_message(), context(), timeout()} |
		  {noreply, context(), timeout()} |
		  {stop, term(), context()}.
handle_message(Message, Context=#?CONTEXT{client_id=undefined}) ->
	% Drop messages from the server before CONNECT.
	% Ping schedule can be reset because we got a packet anyways.
	lager:warning("dropping message ~p before connect", [Message]),
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_connack{code=Code}, Context=#?CONTEXT{client_id=ClientId, state=connecting}) ->
	% Received connack while waiting for one.
	case Code of
		accepted ->
			lager:notice("~p connection granted", [ClientId]),
			{noreply, Context#?CONTEXT{state=connected, timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
		alt_server ->
			lager:notice("~p connection offloaded to ~p", [ClientId, Message#mqtt_connack.alt_server]),
			[T, HP] = binary:split(Message#mqtt_connack.alt_server, [<<"://">>]),
			[H, P] = binary:split(HP, [<<":">>]),
			lager:info("~p, ~p, ~p", [T, H, P]),
			{Transport, Host, Port} = {case T of
										   <<"tcp">> -> ranch_tcp;
										   <<"ssl">> -> ranch_ssl
									   end, binary:bin_to_list(H),
									   case string:to_integer(binary:bin_to_list(P)) of
									   	   {error, _} -> 1883;
									   	   {Int, _} -> Int
									   end},
			fubar:settings(?MODULE, [{transport, Transport}, {host, Host}, {port, Port}]),
			{stop, offloaded, Context};
		_ ->
			lager:error("~p connection rejected", [ClientId]),
			{stop, normal, Context}
	end;
handle_message(Message, Context=#?CONTEXT{client_id=ClientId, state=connecting}) ->
	% Drop messages from the server before CONNACK.
	lager:warning("~p dropping ~p, not connected yet", [ClientId, Message]),
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message, Context=#?CONTEXT{client_id=ClientId, state=disconnecting}) ->
	% Drop messages after DISCONNECT.
	lager:warning("~p dropping ~p, disconnecting", [ClientId, Message]),
	{noreply, Context#?CONTEXT{timestamp=os:timestamp(), timeout=0}, 0};
handle_message(#mqtt_pingresp{}, Context=#?CONTEXT{}) ->
	% Cancel expiration schedule if there is one.
	timer:cancel(Context#?CONTEXT.timer),
	{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_suback{message_id=MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Subscribe complete.  Stop retrying.
	case lists:keytake(MessageId, 1, Context#?CONTEXT.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				Context#?CONTEXT.timeout};
		_ ->
			lager:debug("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message=#mqtt_unsuback{message_id=MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Unsubscribe complete.  Stop retrying.
	case lists:keytake(MessageId, 1, Context#?CONTEXT.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				Context#?CONTEXT.timeout};
		_ ->
			lager:debug("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message=#mqtt_publish{message_id=MessageId}, Context=#?CONTEXT{}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% This is the very point to print a message received.
	case Message#mqtt_publish.qos of
		exactly_once ->
			% Transaction via 3-way handshake.
			Reply = #mqtt_pubrec{message_id=MessageId},
			case Message#mqtt_publish.dup of
				true ->
					case lists:keyfind(MessageId, 1, Context#?CONTEXT.wait_buffer) of
						false ->
							% Not likely but may have missed original.
							Buffer = lists:sublist([{MessageId, Message} | Context#?CONTEXT.wait_buffer],
										Context#?CONTEXT.max_waits),
							{reply, Reply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), wait_buffer=Buffer},
								Context#?CONTEXT.timeout};
						{MessageId, _} ->
							{reply, Reply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()},
								Context#?CONTEXT.timeout}
					end;
				_ ->
					Buffer = lists:sublist([{MessageId, Message} | Context#?CONTEXT.wait_buffer],
								Context#?CONTEXT.max_waits),
					{reply, Reply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), wait_buffer=Buffer},
						Context#?CONTEXT.timeout}
			end;
		at_least_once ->
			% Transaction via 1-way handshake.
			Context1 = feedback(Message, Context),
			{reply, #mqtt_puback{message_id=MessageId}, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()},
				Context1#?CONTEXT.timeout};
		_ ->
			Context1 = feedback(Message, Context),
			{noreply, Context1#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message=#mqtt_puback{message_id=MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Complete a 1-way handshake transaction.
	case lists:keytake(MessageId, 1, Context#?CONTEXT.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				Context#?CONTEXT.timeout};
		_ ->
			lager:debug("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message=#mqtt_pubrec{message_id=MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Commit a 3-way handshake transaction.
	case lists:keytake(MessageId, 1, Context#?CONTEXT.retry_pool) of
		{value, {MessageId, Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			Reply = #mqtt_pubrel{message_id=MessageId},
			{ok, NewTimer} = timer:send_after(Context#?CONTEXT.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Request, Context#?CONTEXT.max_retries, NewTimer} | Rest],
			{reply, Reply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), retry_pool=Pool},
				Context#?CONTEXT.timeout};
		_ ->
			lager:debug("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message=#mqtt_pubrel{message_id=MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Complete a server-driven 3-way handshake transaction.
	case lists:keytake(MessageId, 1, Context#?CONTEXT.wait_buffer) of
		{value, {MessageId, Request}, Rest} ->
			feedback(ClientId, Request),
			Reply = #mqtt_pubcomp{message_id=MessageId},
			{reply, Reply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), wait_buffer=Rest},
				Context#?CONTEXT.timeout};
		_ ->
			lager:debug("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message=#mqtt_pubcomp{message_id=MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Complete a 3-way handshake transaction.
	case lists:keytake(MessageId, 1, Context#?CONTEXT.retry_pool) of
		{value, {MessageId, _Request, _, Timer}, Rest} ->
			timer:cancel(Timer),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), retry_pool=Rest},
				Context#?CONTEXT.timeout};
		_ ->
			lager:debug("~p possibly abandoned ~p", [ClientId, Message]),
			{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}
	end;
handle_message(Message, Context) ->
	timer:cancel(Context#?CONTEXT.timer),
	% Drop unknown messages from the server.
	lager:warning("~p dropping unknown ~p", [Context#?CONTEXT.client_id, Message]),
	{noreply, Context#?CONTEXT{timer=undefined, timestamp=os:timestamp()}, Context#?CONTEXT.timeout}.

-spec handle_event(Event :: term(), context()) ->
		  {reply, mqtt_message(), context(), timeout()} |
		  {noreply, context(), timeout()} |
		  {stop, term(), context()}.
handle_event({context, From}, Context) ->
	From ! Context,
	{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
handle_event({state, From}, Context) ->
	From ! Context#?CONTEXT.state,
	{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
handle_event({last_message, From}, Context) ->
	From ! Context#?CONTEXT.last_message,
	{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
handle_event(timeout, Context=#?CONTEXT{client_id=undefined}) ->
	lager:error("impossible overload timeout"),
	{stop, normal, Context};
handle_event(timeout, Context=#?CONTEXT{client_id=ClientId, state=connecting}) ->
	lager:info("~p connect timed out", [ClientId]),
	{stop, no_connack, Context};
handle_event(timeout, Context=#?CONTEXT{state=disconnecting}) ->
	{stop, normal, Context};
handle_event(timeout, Context) ->
	{ok, Timer} = timer:send_after(Context#?CONTEXT.retry_after, no_pingresp),
	{reply, #mqtt_pingreq{}, Context#?CONTEXT{timestamp=os:timestamp(), timer=Timer}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_connect{}, Context=#?CONTEXT{client_id=undefined}) ->
	lager:debug("~p connecting", [Event#mqtt_connect.client_id]),
	{reply, Event, Context#?CONTEXT{
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
						state=connecting}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_subscribe{}, Context) ->
	case Event#mqtt_subscribe.qos of
		at_most_once ->
			% This is out of spec. but trying.  Why not?
			{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()},
				timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
		_ ->
			timer:cancel(Context#?CONTEXT.timer),
			MessageId = Context#?CONTEXT.message_id rem 16#ffff + 1,
			Message = Event#mqtt_subscribe{message_id=MessageId, qos=at_least_once},
			Dup = Message#mqtt_subscribe{dup=true},
			{ok, Timer} = timer:send_after(Context#?CONTEXT.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | Context#?CONTEXT.retry_pool],
			{reply, Message,
			 Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), message_id=MessageId, retry_pool=Pool},
			 Context#?CONTEXT.timeout}
	end;
handle_event(Event=#mqtt_unsubscribe{}, Context) ->
	timer:cancel(Context#?CONTEXT.timer),
	case Event#mqtt_unsubscribe.qos of
		at_most_once ->
			% This is out of spec. but trying.  Why not?
			{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()},
				timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
		_ ->
			timer:cancel(Context#?CONTEXT.timer),
			MessageId = Context#?CONTEXT.message_id rem 16#ffff + 1,
			Message = Event#mqtt_unsubscribe{message_id=MessageId, qos=at_least_once},
			Dup = Message#mqtt_unsubscribe{dup=true},
			{ok, Timer} = timer:send_after(Context#?CONTEXT.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | Context#?CONTEXT.retry_pool],
			{reply, Message,
			 Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), message_id=MessageId, retry_pool=Pool},
			 Context#?CONTEXT.timeout}
	end;
handle_event(Event=#mqtt_publish{}, Context) ->
	case Event#mqtt_publish.qos of
		at_most_once ->
			{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()},
				timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
		_ ->
			timer:cancel(Context#?CONTEXT.timer),
			MessageId = Context#?CONTEXT.message_id rem 16#ffff + 1,
			Message = Event#mqtt_publish{message_id=MessageId},
			Dup = Message#mqtt_publish{dup=true},
			{ok, Timer} = timer:send_after(Context#?CONTEXT.retry_after, {retry, MessageId}),
			Pool = [{MessageId, Dup, 1, Timer} | Context#?CONTEXT.retry_pool],
			{reply, Message,
			 Context#?CONTEXT{timer=undefined, timestamp=os:timestamp(), message_id=MessageId, retry_pool=Pool},
			 Context#?CONTEXT.timeout}
	end;
handle_event(Event=#mqtt_disconnect{}, Context) ->
	timer:cancel(Context#?CONTEXT.timer),
	{reply, Event, Context#?CONTEXT{timer=undefined, state=disconnecting, timestamp=os:timestamp(), timeout=0}, 0};

handle_event({retry, MessageId}, Context=#?CONTEXT{client_id=ClientId}) ->
	case lists:keytake(MessageId, 1, Context#?CONTEXT.retry_pool) of
		{value, {MessageId, Message, Retry, _}, Rest} ->
			case Retry < Context#?CONTEXT.max_retries of
				true ->
					{ok, Timer} = timer:send_after(Context#?CONTEXT.retry_after, {retry, MessageId}),
					Pool = [{MessageId, Message, Retry+1, Timer} | Rest],
					{reply, Message, Context#?CONTEXT{timestamp=os:timestamp(), retry_pool=Pool},
						Context#?CONTEXT.timeout};
				_ ->
					lager:warning("~p dropping event ~p after retry", [ClientId, Message]),
					{noreply, Context#?CONTEXT{retry_pool=Rest},
						timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)}
			end;
		_ ->
			lager:error("~p no such retry ~p", [ClientId, MessageId]),
			{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)}
	end;
handle_event(Event, Context=#?CONTEXT{client_id=ClientId, state=connecting}) ->
	lager:warning("~p dropping event ~p before connack", [ClientId, Event]),
	{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)};
handle_event(no_pingresp, Context=#?CONTEXT{client_id=ClientId}) ->
	lager:info("~p connection lost", [ClientId]),
	{stop, no_pingresp, Context};
handle_event(Event, Context) ->
	lager:warning("~p dropping unknown event ~p", [Context#?CONTEXT.client_id, Event]),
	{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)}.

%% @doc Finalize the client process.
-spec terminate(term(), context()) -> term().
terminate(normal, #?CONTEXT{state=disconnecting}) ->
	normal;
terminate(Reason, _Context) ->
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

%% Print message to log
feedback(#mqtt_publish{topic=Topic, payload=Payload}, Context=#?CONTEXT{client_id=ClientId}) ->
	lager:notice("~p received publish ~p from ~p", [ClientId, Payload, Topic]),
	Context#?CONTEXT{last_message=Payload};
feedback(Message, Context=#?CONTEXT{client_id=ClientId}) ->
	lager:error("~p received unknown message ~p", [ClientId, Message]),
	Context.

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
