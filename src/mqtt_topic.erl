%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT topic endpoint for fubar system.
%%%    This performs mqtt pubsub in fubar messaging system.  It is
%%% another mqtt endpoint with mqtt_session.  This is designed to form
%%% hierarchical subscription relationships among themselves to scale
%%% more than millions of subscribers in a logical topic.
%%%
%%% Created : Nov 18, 2012
%%% -------------------------------------------------------------------
-module(mqtt_topic).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Exports
%%
-export([mnesia/1,	% Database preparations
		 start/1,	% start a topic
		 state/1,	% state query
		 trace/2]).	% set trace flag true/false

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").
-include_lib("stdlib/include/qlc.hrl").

%% @doc Subscriber database schema.
-record(mqtt_subscriber, {id = '_' :: binary(),			% primary key
						  topic = '_' :: binary(),		% topic name
						  client_id = '_' :: binary(),	% subscriber
						  qos = '_' :: mqtt_qos(),		% max qos
						  module = '_' :: module()}).	% subscriber type

%% @doc Retained message database schema.
-record(mqtt_retained, {topic = '_' :: binary(),	% topic name
						fubar = '_' :: #fubar{}}).	% fubar to send to new subscribers

%% Auto start-up attributes
-create_mnesia_tables({mnesia, [create_tables]}).
-merge_mnesia_tables({mnesia, [merge_tables]}).
-split_mnesia_tables({mnesia, [split_tables]}).

-define(MNESIA_TIMEOUT, 10000).

%% @doc Mnesia table manipulations.
mnesia(create_tables) ->
	mnesia:create_table(mqtt_subscriber, [{attributes, record_info(fields, mqtt_subscriber)},
										  {disc_copies, [node()]}, {type, set},
										  {index, [topic, client_id]}]),
	mnesia:create_table(mqtt_retained, [{attributes, record_info(fields, mqtt_retained)},
										{disc_copies, [node()]}, {type, set},
										{local_content, true}]),
	ok = mnesia:wait_for_tables([mqtt_subscriber, mqtt_retained], ?MNESIA_TIMEOUT);
mnesia(merge_tables) ->
	{atomic, ok} = mnesia:add_table_copy(mqtt_subscriber, node(), disc_copies),
	{atomic, ok} = mnesia:add_table_copy(mqtt_retained, node(), disc_copies);
mnesia(split_tables) ->
	mnesia:del_table_copy(mqtt_subscriber, node()),
	mnesia:del_table_copy(mqtt_retained, node()).

-define(STATE, ?MODULE).

%% @doc MQTT topic state
-record(?STATE, {
		name :: binary(),	% topic name
		subscribers = [] ::
			[{Id :: binary(), ClientId :: binary(), mqtt_qos(), Monitor :: term(), Session :: pid(), module()}],
		fubar :: fubar(),	% retained fubar
		trace = false :: boolean()	% trace flag
}).

-type state() :: #?STATE{}.

%% @doc Start a topic.
-spec start(params()) -> {ok, pid()}.
start(Props) ->
	State = ?PROPS_TO_RECORD(Props, ?STATE),
	gen_server:start(?MODULE, State, []).

%% @doc State query.
-spec state(pid() | binary()) -> {ok, state()} | {error, Reason :: term()}.
state(Topic) when is_pid(Topic) ->
	gen_server:call(Topic, state);
state(Name) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Topic, ?MODULE, _}} ->
			state(Topic);
		Error ->
			Error
	end.

%% @doc Start or stop tracing.
-spec trace(pid() | binary(), boolean()) -> ok | {error, Reason :: term()}.
trace(Topic, Value) when is_pid(Topic) ->
	gen_server:call(Topic, {trace, Value});
trace(Name, Value) ->
	case fubar_route:ensure(Name, ?MODULE) of
		{ok, {Topic, ?MODULE, _}} ->
			trace(Topic, Value);
		Error ->
			Error
	end.

init(State=#?STATE{name=Name}) ->
	% Restore all the subscriptions and retained message from database.
	process_flag(trap_exit, true),
	lager:debug("init ~p", [State]),
	Q = qlc:q([{Id, ClientId, QoS, undefined, undefined, Module} ||
				   #mqtt_subscriber{id=Id, topic=Topic, client_id=ClientId, qos=QoS, module=Module}
					   <- mnesia:table(mqtt_subscriber),
				   Topic =:= Name]),
	Subscribers = mnesia:async_dirty(fun() -> qlc:e(Q) end),
	Fubar = case mnesia:dirty_read(mqtt_retained, Name) of
				[#mqtt_retained{topic=Name, fubar=Value}] -> Value;
				[] -> undefined
			end,
	case fubar_route:sync_up(Name, ?MODULE) of
		ok ->
			lager:notice("~p init ok", [Name]),
			{ok, State#?STATE{subscribers=Subscribers, fubar=Fubar}};
		Error ->
			lager:error("~p init error ~p", [Name, Error]),
			{stop, Error}
	end.

%% State query for admin operation.
handle_call(state, _, State) ->
	{reply, {ok, State}, State};

handle_call({trace, Value}, _, State=#?STATE{name=Name}) ->
	fubar_route:update(Name, {trace, Value}),
	lager:notice("~p TRACE ~p", [Name, Value]),
	{reply, ok, State#?STATE{trace=Value}};

%% Subscribe request from a client session.
handle_call(Fubar=#fubar{payload={subscribe, QoS, Module, Pid}}, _, State=#?STATE{name=Name}) ->
	erlang:garbage_collect(),
	case fubar:get(to, Fubar) of
		Name ->
			Subscribers = subscribe(Name, {fubar:get(from, Fubar), Pid}, {QoS, Module}, State#?STATE.subscribers),
			case State#?STATE.fubar of
				undefined ->
					ok;
				Retained ->
					gen_server:cast(Pid, fubar:set([{to, fubar:get(from, Fubar)}, {via, Name}], Retained))
			end,
			{reply, {ok, QoS}, State#?STATE{subscribers=Subscribers}};
		_ ->
			lager:error("~p not my fubar ~p", [Name, Fubar]),
			{reply, ok, State}
	end;

%% Unsubscribe request from a client session.
handle_call(Fubar=#fubar{payload=unsubscribe}, _, State=#?STATE{name=Name}) ->
	erlang:garbage_collect(),
	case fubar:get(to, Fubar) of
		Name ->
			Subscribers = unsubscribe(Name, fubar:get(from, Fubar), State#?STATE.subscribers),
			{reply, ok, State#?STATE{subscribers=Subscribers}};
		_ ->
			lager:error("~p not my fubar ~p", [Name, Fubar]),
			{reply, ok, State}
	end;

%% Fallback
handle_call(Request, From, State) ->
	lager:warning("~p unknown call ~p, ~p", [State#?STATE.name, Request, From]),
	{reply, ok, State}.

%% Subscribe request from a client session.
handle_cast(Fubar=#fubar{payload={subscribe, QoS, Module, Pid}}, State=#?STATE{name=Name}) ->
	erlang:garbage_collect(),
	case fubar:get(to, Fubar) of
		Name ->
			Subscribers = subscribe(Name, {fubar:get(from, Fubar), Pid}, {QoS, Module}, State#?STATE.subscribers),
			case State#?STATE.fubar of
				undefined ->
					ok;
				Retained ->
					gen_server:cast(Pid, fubar:set([{to, fubar:get(from, Fubar)}, {via, Name}], Retained))
			end,
			{noreply, State#?STATE{subscribers=Subscribers}};
		_ ->
			lager:error("~p not my fubar ~p", [Name, Fubar]),
			{noreply, State}
	end;

%% Unsubscribe request from a client session.
handle_cast(Fubar=#fubar{payload=unsubscribe}, State=#?STATE{name=Name}) ->
	erlang:garbage_collect(),
	case fubar:get(to, Fubar) of
		Name ->
			Subscribers = unsubscribe(Name, fubar:get(from, Fubar), State#?STATE.subscribers),
			{noreply, State#?STATE{subscribers=Subscribers}};
		_ ->
			lager:error("~p not my fubar ~p", [Name, Fubar]),
			{noreply, State}
	end;

%% Publish request.
handle_cast(Fubar=#fubar{payload=#mqtt_publish{}}, State=#?STATE{name=Name, trace=Trace}) ->
	erlang:garbage_collect(),
	case fubar:get(to, Fubar) of
		Name ->
			{Fubar1, Subscribers} = publish(Name, Fubar, State#?STATE.subscribers, Trace),
			Publish = fubar:get(payload,Fubar1),
			case Publish#mqtt_publish.retain of
				true ->
					mnesia:dirty_write(#mqtt_retained{topic=Name, fubar=Fubar1}),
					{noreply, State#?STATE{fubar=Fubar1, subscribers=Subscribers}};
				_ ->
					{noreply, State#?STATE{subscribers=Subscribers}}
			end;
		_ ->
			lager:error("~p not my fubar ~p", [Name, Fubar]),
			{noreply, State}
	end;

%% Fallback
handle_cast(Message, State) ->
	lager:warning("~p unknown cast ~p", [State#?STATE.name, Message]),
	{noreply, State}.

%% Likely to be a subscriber down event
handle_info({'DOWN', Monitor, _, Pid, Reason}, State=#?STATE{name=Name}) ->
	case lists:keytake(Monitor, 4, State#?STATE.subscribers) of
		{value, {Id, ClientId, QoS, Monitor, Pid, Module}, Subscribers} ->
			lager:debug("~p subscriber ~p down by ~p", [Name, Pid, Reason]),
			{noreply, State#?STATE{subscribers=[{Id, ClientId, QoS, undefined, undefined, Module} | Subscribers]}};
		false ->
			lager:debug("~p unknown ~p down by ~p", [Name, Pid, Reason]),
			{noreply, State}
	end;
%% Fallback
handle_info(Info, State) ->
	lager:warning("~p unknown info ~p", [State#?STATE.name, Info]),
	{noreply, State}.

terminate(Reason, #?STATE{name=Name}) ->
	lager:notice("~p terminating by ~p", [Name, Reason]),
	case fubar_route:down(Name) of
		ok ->
			ok;
		Error ->
			lager:error("~p terminate not graceful ~p", [Name, Error])
	end,
	Reason.
	
code_change(OldVsn, State, Extra) ->
	lager:debug("code change from ~p while ~p, ~p", [OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local
%%
publish(Name, Fubar, Subscribers, Trace) ->
	Publish = fubar:get(payload, Fubar),
	QoS = Publish#mqtt_publish.qos,
	Fubar1 =
		case Trace and (fubar:get(id, Fubar) =:= undefined) of
			true -> fubar:set([{id, uuid:get_v4()}, {via, Name}], Fubar);
			_ -> fubar:set([{via, Name}], Fubar)
		end,
	F = fun({Id, ClientId, MaxQoS, Monitor, Pid, Module}) ->
			Publish1 = Publish#mqtt_publish{qos=mqtt:degrade(QoS, MaxQoS)},
			Fubar2 = fubar:set([{to, ClientId}, {payload, Publish1}], Fubar1),
			case Pid of
				undefined ->
					case fubar_route:ensure(ClientId, Module) of
						{ok, {Addr, Module, Trace1}} ->
							Fubar3 =
								case Trace1 and (fubar:get(id, Fubar2) =:= undefined) of
									true -> fubar:set([{id, uuid:get_v4()}], Fubar2);
									_ -> Fubar2
								end,
							NewMonitor = monitor(process, Addr),
							catch gen_server:cast(Addr, Fubar3),
							{Id, ClientId, MaxQoS, NewMonitor, Addr, Module};
						_ ->
							lager:error("~p can't ensure a subscriber ~p", [Name, ClientId]),
							{Id, ClientId, MaxQoS, undefined, undefined, Module}
					end;
				_ ->
					catch gen_server:cast(Pid, Fubar2),
					{Id, ClientId, MaxQoS, Monitor, Pid, Module}
			end
		end,
	{Fubar1, lists:map(F, Subscribers)}.

subscribe(Name, {ClientId, Pid}, {QoS, Module}, Subscribers) ->
	% Check if it's a new subscription or not.
	case lists:keytake(ClientId, 2, Subscribers) of
		{value, {Id, ClientId, QoS, OldMonitor, _, Module}, Rest} ->
			% The same subscription from possibly different client.
			catch demonitor(OldMonitor, [flush]),
			Monitor = monitor(process, Pid),
			[{Id, ClientId, QoS, Monitor, Pid, Module} | Rest];
		{value, {Id, ClientId, _, OldMonitor, _, _}, Rest} ->
			% Need to update the subscription.
			catch demonitor(OldMonitor, [flush]),
			mnesia:dirty_write(#mqtt_subscriber{id=Id, topic=Name, client_id=ClientId, qos=QoS, module=Module}),
			Monitor = monitor(process, Pid),
			[{Id, ClientId, QoS, Monitor, Pid, Module} | Rest];
		false ->
			% Not found.  This is a new one.
			Id = uuid:get_v4(),
			mnesia:dirty_write(#mqtt_subscriber{id=Id, topic=Name, client_id=ClientId, qos=QoS, module=Module}),
			Monitor = monitor(process, Pid),
			[{Id, ClientId, QoS, Monitor, Pid, Module} | Subscribers]
	end.

unsubscribe(_Name, ClientId, Subscribers) ->
	case lists:keytake(ClientId, 2, Subscribers) of
		{value, {Id, ClientId, _, Monitor, _, _}, Rest} ->
			catch demonitor(Monitor, [flush]),
			mnesia:dirty_delete({mqtt_subscriber, Id}),
			Rest;
		false ->
			Subscribers
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
