%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT server.
%%%    This is designed to run under mqtt_protocol as a dispather.
%%% CONNECT, PINGREQ and DISCONNECT messages are processed here but
%%% others not.  All the other messages are just delivered to
%%% the session which is a separate process that typically survives
%%% longer.  Note that this performs just as a delivery channel and
%%% most of the logics are implemented in mqtt_session.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt_server).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

%%
%% Types and records
%%
-record(?MODULE, {client_id :: binary(),
				  auth :: module(),
				  session :: pid(),
				  valid_keep_alive :: undefined | {integer(), integer()},
				  timeout = 10000 :: timeout(),
				  timestamp :: timestamp()}).

-type state() :: #?MODULE{}.
-type event() :: any().

%%
%% Exports
%%
-export([init/1, handle_message/2, handle_event/2, terminate/1]).

%%
%% Calback Functions
%%

%% @doc Initialize the server process.
%% This is called when the connection is established.
-spec init(proplist(atom(), term())) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason()}.
init(Props) ->
	DefaultState = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),
	State = ?PROPS_TO_RECORD(Props, ?MODULE, DefaultState)(),
	fubar_log:debug(?MODULE, [undefined, init, State]),
	% Don't respond anything against tcp connection and apply small initial timeout.
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle MQTT messages.
%% This is called when an MQTT message arrives.
-spec handle_message(mqtt_message(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_message(Message=#mqtt_connect{client_id=ClientId, username=undefined},
			   State=#?MODULE{session=undefined, timeout=Timeout, timestamp=Timestamp}) ->
	fubar_log:protocol(?MODULE, [ClientId, "=>", Message]),
	case State#?MODULE.auth of
		undefined ->
			bind_session(Message, State);
		_ ->
			% Give another chance to connect with right credential again.
			fubar_log:warning(?MODULE, [ClientId, "no username"]),
			{reply, mqtt:connack([{code, unauthorized}]), State, timeout(Timeout, Timestamp)}
	end;
handle_message(Message=#mqtt_connect{client_id=ClientId, username=Username},
			   State=#?MODULE{session=undefined, timeout=Timeout}) ->
	fubar_log:protocol(?MODULE, [ClientId, "=>", Message]),
	case State#?MODULE.auth of
		undefined ->
			bind_session(Message, State);
		Auth ->
			% Connection with credential.
			case Auth:verify(Username, Message#mqtt_connect.password) of
				ok ->
					% The client is authorized.
					% Now bind with the session or create a new one.
					fubar_log:access(?MODULE, [ClientId, "authorized", Username]),
					bind_session(Message, State);
				{error, not_found} ->
					fubar_log:warning(?MODULE, [ClientId, "wrong username", Username]),
					{reply, mqtt:connack([{code, id_rejected}]), State#?MODULE{timestamp=now()}, 0};
				{error, forbidden} ->
					fubar_log:warning(?MODULE, [ClientId, "wrong password", Username]),
					{reply, mqtt:connack([{code, forbidden}]), State#?MODULE{timestamp=now()}, 0};
				Error ->
					fubar_log:error(?MODULE, ["error in auth module", Auth, Error]),
					{reply, mqtt:connack([{code, unavailable}]), State#?MODULE{timestamp=now()}, Timeout}
			end
	end;
handle_message(Message, State=#?MODULE{session=undefined}) ->
	% All the other messages are not allowed without session.
	fubar_log:protocol(?MODULE, [undefined, "=>", Message]),
	fubar_log:warning(?MODULE, [Message, "before mqtt_connect{}"]),
	{stop, normal, State#?MODULE{timestamp=now()}};
handle_message(Message=#mqtt_pingreq{}, State) ->
	% Reflect ping and refresh timeout.
	fubar_log:debug(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Reply = #mqtt_pingresp{},
	fubar_log:debug(?MODULE, [State#?MODULE.client_id, "<=", Reply]),
	{reply, Reply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_publish{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_puback{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubrec{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubrel{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_pubcomp{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_subscribe{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_unsubscribe{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	Session ! Message,
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_message(Message=#mqtt_disconnect{}, State=#?MODULE{session=Session}) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "=>", Message]),
	mqtt_session:stop(Session),
	{stop, normal, State#?MODULE{timestamp=now()}};

%% Fallback
handle_message(Message, State) ->
	fubar_log:warning(?MODULE, [State#?MODULE.client_id, "=>", Message, "unknown message"]),
	{noreply, State#?MODULE{timestamp=now()}, State#?MODULE.timeout}.

%% @doc Handle internal events from, supposedly, the session.
-spec handle_event(event(), state()) ->
		  {reply, mqtt_message(), state(), timeout()} |
		  {reply_later, mqtt_message(), state(), timeout()} |
		  {noreply, state(), timeout()} |
		  {stop, reason(), state()}.
handle_event(timeout, State=#?MODULE{client_id=ClientId}) ->
	% General timeout
	fubar_log:warning(?MODULE, [ClientId, "timed out"]),
	{stop, normal, State};
handle_event(Event, State=#?MODULE{session=undefined}) ->
	fubar_log:error(?MODULE, [State#?MODULE.client_id, "sessionless event", Event]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)};
handle_event(Event=#mqtt_publish{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_puback{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubrec{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubrel{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_pubcomp{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_suback{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};
handle_event(Event=#mqtt_unsuback{}, State) ->
	fubar_log:protocol(?MODULE, [State#?MODULE.client_id, "<=", Event]),
	{reply, Event, State#?MODULE{timestamp=now()}, State#?MODULE.timeout};

%% Fallback
handle_event(Event, State) ->
	fubar_log:debug(?MODULE, [State#?MODULE.client_id, Event, "unknown event"]),
	{noreply, State, timeout(State#?MODULE.timeout, State#?MODULE.timestamp)}.

%% @doc Finalize the server process.
-spec terminate(state()) -> ok.
terminate(#?MODULE{client_id=ClientId}) ->
	fubar_log:debug(?MODULE, [ClientId, terminate]),
	normal;
terminate(_) ->
	normal.

%%
%% Local Functions
%%
timeout(infinity, _) ->
	infinity;
timeout(Milliseconds, Timestamp) ->
	Elapsed = timer:now_diff(now(), Timestamp) div 1000,
	case Milliseconds > Elapsed of
		true -> Milliseconds - Elapsed;
		_ -> 0
	end.

bind_session(Message=#mqtt_connect{client_id=ClientId}, State) ->
	% Once bound, the session will detect process termination.
	% Timeout value should be set as requested.
	Will = case Message#mqtt_connect.will_topic of
			   undefined -> undefined;
			   Topic -> {Topic, Message#mqtt_connect.will_message,
						 Message#mqtt_connect.will_qos, Message#mqtt_connect.will_retain}
		   end,
	case mqtt_session:bind(ClientId, Will) of
		{ok, Session} ->
			fubar_log:access(?MODULE, [ClientId, "session bound", Session]),
			KeepAlive = determine_keep_alive(Message#mqtt_connect.keep_alive, State#?MODULE.valid_keep_alive),
			% Set timeout as 1.5 times the keep-alive.
			Timeout = KeepAlive*1500,
			Reply = case KeepAlive =:= Message#mqtt_connect.keep_alive of
						true -> mqtt:connack([{code, accepted}]);
						% MQTT extension: server may suggest different keep-alive.
						_ -> mqtt:connack([{code, accepted}, {extra, <<KeepAlive:16/big-unsigned>>}])
					end,
			case Message#mqtt_connect.clean_session of
				true -> mqtt_session:clean(Session);
				_ -> ok
			end,
			fubar_log:protocol(?MODULE, [ClientId, "<=", Reply]),
			{reply, Reply,
			 State#?MODULE{client_id=ClientId, session=Session, timeout=Timeout, timestamp=now()}, Timeout};
		Error ->
			fubar_log:error(?MODULE, [ClientId, "session bind failure", Error]),
			Reply = mqtt:connack([{code, unavailable}]),
			fubar_log:protocol(?MODULE, [ClientId, "<=", Reply]),
			% Timeout immediately to close just after reply.
			{reply, Reply, State#?MODULE{client_id=ClientId, timestamp=now()}, State#?MODULE.timeout}
	end.

determine_keep_alive(Suggested, {Min, _}) when Suggested < Min ->
	Min;
determine_keep_alive(Suggested, {_, Max}) when Suggested > Max ->
	Max;
determine_keep_alive(Suggested, _) ->
	Suggested.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.