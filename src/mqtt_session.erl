%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT session for fubar system.
%%%     This plays as a persistent mqtt endpoint in fubar messaging
%%% system.  The mqtt_server may up or down as a client connects or
%%% disconnects but this keeps running and survives unwilling client
%%% disconnection.  The session gets down only when the client sets
%%% clean_session and sends DISCONNECT.  While running, it buffers
%%% messages to the client until it gets available.
%%%
%%% Created : Nov 15, 2012
%%% -------------------------------------------------------------------
-module(mqtt_session).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Exports
%%
-export([start/1,	% start a session without binding
		 stop/1,	% stop a session
		 bind/3,	% find or start a session and bind with calling process
		 clean/1,	% unsubscribe all subscriptions
		 setopts/2,	% set socket options to override default
		 max_age/1,	% get max age of the session
		 max_age/2, % set max age of the session
		 state/1,	% get session state
		 trace/2]).	% set trace true/false, fubars created by this session are traced

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3,
		 transaction_loop/4, handle_alert/2]).

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

-define(MIGRATION_TIMEOUT, 1000).

-define(STATE, ?MODULE).

-record(?STATE, {
		name :: binary(),	% usually client_id
		socket_options :: params(),	% socket options to override.
		subscriptions = [] :: [{binary(), mqtt_qos()}],	% [{topic, qos}]
		client :: pid(),	% mqtt_server process
		username :: nil | binary(), % current username used to connect mqtt
		will :: {binary(), binary(), mqtt_qos(), boolean()},	% {topic, payload, qos, retain}
		timestamp :: {integer(), integer(), integer()}, % timestamp when a client is disconnected.
		max_age = 172800000 :: integer(), % max lifetime of offline session. 2 days by default.
		transactions = [] :: [{integer(), pid(), mqtt_message()}], % [{message_id, transaction_loop, reply}]
		transaction_timeout = 60000 :: timeout(),	% drop transactions not complete in this timeout
		message_id = 0 :: integer(),	% last message_id used by this session
		buffer = [] :: [#fubar{}],	% fubar buffer for offline client
		buffer_limit = 3 :: integer(),	% fubar buffer length
		retry_pool = [] :: [{integer(), #fubar{}, integer(), term()}],	% retry pool for downlink transaction
		max_retries = 5 :: integer(),	% drop downlink transactions after retry
		retry_after = 10000 :: timeout(),	% downlink transactions retry policy
		trace = false :: boolean(),	% sets trace flag on for fubars created by this session
		alert = false :: boolean()	% runs gc on every reduction when this flag is set
}).

-type state() :: #?STATE{}.

%% @doc Start mqtt_session (unbound).
-spec start(params()) -> {ok, pid()} | {error, Reason :: term()}.
start(Params) ->
	State = ?PROPS_TO_RECORD(Params++fubar:settings(?MODULE), ?STATE),
	gen_server:start(?MODULE, State, []).

%% @doc Stop mqtt_session.
-spec stop(pid() | binary()) -> ok | {error, Reason :: term()}.
stop(Session) when is_pid(Session) ->
	gen_server:cast(Session, stop);
stop(Name) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			% The session is temporarily down.
			fubar_route:clean(Name);
		{ok, {Session, ?MODULE, _}} ->
			stop(Session);
		Error ->
			Error
	end.

%% @doc Bind a client to existing session or create a new one.
-spec bind(ClientId :: term(), Username :: binary(), params()) ->
		{ok, pid()} | {error, Reason :: term()}.
bind(ClientId, Username, Will) ->
	case fubar_route:resolve(ClientId) of
		{ok, {undefined, ?MODULE, _}} ->
			{ok, Pid} = start([{name, ClientId}]),
			gen_server:call(Pid, {bind, Username, Will});
		{ok, {Session, ?MODULE, _}} ->
			gen_server:call(Session, {bind, Username, Will});
		{error, not_found} ->
			{ok, Pid} = start([{name, ClientId}]),
			gen_server:call(Pid, {bind, Username, Will});
		Error ->
			Error
	end.

%% @doc Clean all the subscriptions.
-spec clean(pid() | binary()) -> ok | {error, Reason :: term()}.
clean(Session) when is_pid(Session) ->
	gen_server:cast(Session, clean);
clean(Name) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Session, ?MODULE, _}} ->
			clean(Session);
		Error ->
			Error
	end.

%% @doc Set socket options to override defaults.
-spec setopts(pid() | binary(), params()) -> ok | {error, Reason :: term()}.
setopts(Session, Options) when is_pid(Session) ->
	gen_server:call(Session, {setopts, Options});
setopts(Name, Options) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Session, ?MODULE, _}} ->
			setopts(Session, Options);
		Error ->
			Error
	end.

%% @doc Get max age of the session.
-spec max_age(pid() | binary()) -> {ok, integer()} | {error, Reason :: term()}.
max_age(Session) when is_pid(Session) ->
	gen_server:call(Session, max_age);
max_age(Name) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Session, ?MODULE, _}} ->
			max_age(Session);
		Error ->
			Error
	end.

%% @doc Set max age of the session.
-spec max_age(pid() | binary(), Millisec :: integer()) ->
		ok | {error, Reason :: term()}.
max_age(Session, Value) when is_pid(Session) ->
	gen_server:call(Session, {max_age, Value});
max_age(Name, Value) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Session, ?MODULE, _}} ->
			max_age(Session, Value);
		Error ->
			Error
	end.

%% @doc Get session state.
-spec state(pid() | binary()) -> {ok, state()} | {error, Reason :: term()}.
state(Session) when is_pid(Session) ->
	gen_server:call(Session, state);
state(Name) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Session, ?MODULE, _}} ->
			state(Session);
		Error ->
			Error
	end.

%% @doc Start or stop tracing messages from this session.
-spec trace(pid() | binary(), boolean()) -> ok | {error, Reason :: term()}.
trace(Session, Value) when is_pid(Session) ->
	gen_server:call(Session, {trace, Value});
trace(Name, Value) ->
	case fubar_route:resolve(Name) of
		{ok, {undefined, ?MODULE, _}} ->
			{error, inactive};
		{ok, {Session, ?MODULE, _}} ->
			trace(Session, Value);
		Error ->
			Error
	end.

%% Session start-up sequence.
init(State) ->
	process_flag(trap_exit, true),	% to detect client or transaction down
	lager:debug("init ~p", [State]),
	case fubar_route:up(State#?STATE.name, ?MODULE) of
		ok ->
			lager:notice("session ~p init success", [State#?STATE.name]),
			mqtt_stat:join(sessions),
			{ok, State#?STATE{timestamp=os:timestamp()}, State#?STATE.max_age};
		Error ->
			lager:error("session ~p init failure by ~p", [State#?STATE.name, Error]),
			{stop, Error}
	end.

%% State query for admin operation.
handle_call(state, _, State) ->
	reply({ok, State}, State);

%% Client bind/clean logic for mqtt_server.
handle_call({bind, Username, Will}, {Client, _},
			State=#?STATE{name=Name, transactions=Transactions, retry_pool=RetryPool}) ->
	lager:debug("~p bind call from ~p", [Name, Client]),
	ClientNode = node(Client),
	case {ClientNode =/= node(), Transactions, RetryPool} of
		{true, [], []} -> % Client is from a remote node and I have no outstanding job.
			lager:debug("~p begining session migration logic", [Name]),
			case catch rpc:call(ClientNode, ?MODULE, start,
								[?RECORD_TO_PROPS(State#?STATE{client=undefined, username=nil}, ?STATE)],
								?MIGRATION_TIMEOUT) of
				{ok, Session} ->
					lager:notice("~p session migration complete ~p", [Name, Session]),
					reply(catch gen_server:call(Session, {bind, Username, Will, Client}), State);
				Error ->
					lager:warning("~p session migration failed by ~p", [Name, Error]),
					handle_call({bind, Username, Will, Client}, ignore, State)
			end;
		_ ->
			handle_call({bind, Username, Will, Client}, ignore, State)
	end;
handle_call({bind, Username, Will, Client}, _, State=#?STATE{name=Name, buffer=Buffer}) ->
	% A client attempts to bind when there is already a binding.
	case catch link(Client) of
		true ->
			case State#?STATE.client of
				undefined ->
					lager:info("~p binding with client ~p", [Name, Client]);
				OldClient ->
					lager:info("~p binding with client ~p while killing ~p", [Name, Client, OldClient]),
					catch unlink(OldClient),
					OldClient ! {stop, self()},
					mqtt_stat:leave(State#?STATE.username)
			end,
			case State#?STATE.socket_options of
				undefined -> ok;
				Options -> Client ! {setopts, Options}
			end,
			lists:foreach(fun(Fubar) -> gen_server:cast(self(), Fubar) end, lists:reverse(Buffer)),
			mqtt_stat:join(Username),
			reply({ok, self()}, State#?STATE{client=Client, username=Username, will=Will, buffer=[]});
		Error ->
			lager:warning("~p failed binding with client ~p for ~p", [Name, Client, Error]),
			reply(nok, State)
	end;
handle_call({setopts, Options}, _, State) ->
	% Set socket options for clients of this session.
	case State#?STATE.client of
		undefined -> ok;
		Client -> Client ! {setopts, Options}
	end,
	reply(ok, State#?STATE{socket_options=Options});
handle_call(max_age, _, State=#?STATE{max_age=Value}) ->
	reply({ok, Value}, State);
handle_call({max_age, Value}, _, State) ->
	reply(ok, State#?STATE{max_age=Value});
handle_call({trace, Value}, _, State=#?STATE{name=Name}) ->
	fubar_route:update(Name, {trace, Value}),
	lager:notice("~p TRACE ~p", [Name, Value]),
	reply(ok, State#?STATE{trace=Value});

%% Fallback
handle_call(Request, From, State) ->
	lager:warning("~p unknown call ~p, ~p", [State#?STATE.name, Request, From]),
	reply(ok, State).

%% Clean session.
handle_cast(clean, State=#?STATE{name=Name, transaction_timeout=Timeout, trace=Trace}) ->
	case State#?STATE.subscriptions of
		[] ->
			noreply(State);
		Subscriptions ->
			MessageId = State#?STATE.message_id rem 16#ffff + 1,
			{Topics, _} = lists:unzip(Subscriptions),
			do_transaction(Name, mqtt:unsubscribe([{message_id, MessageId}, {topics, Topics}]), Timeout, Trace),
			noreply(State#?STATE{subscriptions=[]})
	end;

%% Stop.
handle_cast(stop, State) ->
	{stop, normal, State};

%% Message delivery logic to the client.
handle_cast(Fubar=#fubar{to=ClientId}, State=#?STATE{name=ClientId, client=undefined, buffer=Buffer, buffer_limit=N}) ->
	% Got a message to deliver to the client.
	% But it's offline now, keep the message in buffer for later delivery.
	noreply(State#?STATE{buffer=lists:sublist([Fubar | Buffer], N)});
handle_cast(Fubar=#fubar{to=ClientId}, State=#?STATE{name=ClientId, client=Client}) ->
	% Got a message and the client is online.
	% Let's send it to the client.
	case fubar:get(payload, Fubar) of
		Message=#mqtt_publish{} ->
			case Message#mqtt_publish.qos of
				at_most_once ->
					Client ! Message,
					noreply(State);
				_ ->
					MessageId = (State#?STATE.message_id rem 16#ffff) + 1,
					NewMessage= Message#mqtt_publish{message_id=MessageId},
					Client ! NewMessage,
					{ok, Timer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
					Dup = NewMessage#mqtt_publish{dup=true},
					Pool = [{MessageId, fubar:set([{payload, Dup}], Fubar), 1, Timer} | State#?STATE.retry_pool],
					noreply(State#?STATE{message_id=MessageId, retry_pool=Pool})
			end;
		Unknown ->
			lager:debug("~p unknown fubar ~p", [ClientId, Unknown]),
			noreply(State)
	end;
handle_cast(Fubar=#fubar{from={F,T2}, via={V,T3}, to={ClientId,_T4}}, State=#?STATE{name=ClientId}) ->
	Now = os:timestamp(),
	case V of
		undefined ->
			lager:notice("[TRACE] FROM ~p ~p => TO ~p ~p (+~p)ns MSG ~p",
							[F, T2, ClientId, Now, timer:now_diff(Now, T2),
							 fubar:get(payload, Fubar)]);
		_ ->
			case T2 of
				T3 ->
					lager:notice("[TRACE] FROM ~p (not traced) => VIA ~p ~p => TO ~p ~p (+~p)ns MSG ~p",
									[F, V, T3, ClientId, Now, timer:now_diff(Now, T3),
									 fubar:get(payload, Fubar)]);
				_ ->
					lager:notice("[TRACE] FROM ~p ~p => VIA ~p ~p (+~p)ns => TO ~p ~p (+~p)ns MSG ~p",
									[F, T2, V, T3, timer:now_diff(T3, T2), ClientId, Now, timer:now_diff(Now, T2),
									 fubar:get(payload, Fubar)])
			end
	end,
	handle_cast(Fubar#fubar{id=undefined, from=F, to=ClientId, via=V}, State);
handle_cast(Fubar=#fubar{}, State=#?STATE{name=ClientId}) ->
	lager:error("~p got invalid fubar ~p", [ClientId, Fubar]),
	noreply(State);

%% handle_cast({alert, true}, State) ->
%% 	lager:debug("~p alert set", [State#?STATE.name]),
%% 	noreply(State#?STATE{alert=true});
handle_cast({alert, false}, State) ->
	lager:debug("~p alert unset", [State#?STATE.name]),
	noreply(State#?STATE{alert=false});

%% Fallback
handle_cast(Message, State) ->
	lager:warning("~p unknown cast ~p", [State#?STATE.name, Message]),
	noreply(State).

%% Generic stop signal
handle_info({stop, _From}, State) ->
	{stop, normal, State};

%% Handle rare cases related to timing between socket close and publish.
handle_info({recover, Message=#mqtt_publish{topic=Topic}}, State=#?STATE{name=Name, buffer=Buffer, trace=Trace}) ->
	Props = [{from, Topic}, {to, Name}, {via, undefined}, {payload, Message}],
	Fubar = case Trace of
				true -> fubar:create([{id, uuid:get_v4()} | Props]);
				_ -> fubar:create(Props)
			end,
	noreply(State#?STATE{buffer=[Fubar | Buffer]});

%% Message delivery logic to the client (QoS retry).
handle_info({retry, MessageId}, State=#?STATE{client=undefined, buffer=Buffer, buffer_limit=N}) ->
	% This is a retry schedule.
	% But the client is offline.
	% Store the job back to the buffer again.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, Fubar, _Retry, _}, Pool} ->
			lager:info("~p client gone", [State#?STATE.name]),
			noreply(State#?STATE{buffer=lists:sublist([Fubar | Buffer], N), retry_pool=Pool});
		_ ->
			lager:error("~p no such retry ~p", [State#?STATE.name, MessageId]),
			noreply(State)
	end;
handle_info({retry, MessageId}, State=#?STATE{client=Client, buffer=Buffer, buffer_limit=N}) ->
	% Retry schedule arrived.
	% It is for one of publish, pubrel and pubcomp.
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, Fubar, Retry, _}, Pool} ->
			case Retry < State#?STATE.max_retries of
				true ->
					Client ! fubar:get(payload, Fubar),
					{ok, Timer} = timer:send_after(State#?STATE.retry_after, {retry, MessageId}),
					noreply(State#?STATE{retry_pool=[{MessageId, Fubar, Retry+1, Timer} | Pool]});
				_ ->
					lager:info("~p client unreachable", [State#?STATE.name]),
					Client ! {stop, self()},
					noreply(State#?STATE{retry_pool=Pool, buffer=lists:sublist([Fubar | Buffer], N)})
			end;
		_ ->
			lager:error("~p no such retry ~p", [State#?STATE.name, MessageId]),
			noreply(State)
	end;

%% Transaction logic from the client.
handle_info(Info=#mqtt_publish{message_id=MessageId, dup=true}, State) ->
	% This is inbound duplicate publish.
	erlang:garbage_collect(),
	case lists:keyfind(MessageId, 1, State#?STATE.transactions) of
		false ->
			% Not found, not very likely but treat this as a new request.
			handle_info(Info#mqtt_publish{dup=false}, State);
		{MessageId, _, _} ->
			% Found one, drop this.
			lager:debug("~p dropping duplicate publish ~p", [State#?STATE.name, MessageId]),
			noreply(State)
	end;
handle_info(Info=#mqtt_publish{message_id=MessageId},
			State=#?STATE{name=ClientId, transactions=Transactions, transaction_timeout=Timeout, trace=Trace}) ->
	erlang:garbage_collect(),
	case Info#mqtt_publish.qos of
		exactly_once ->
			% Start 3-way handshake transaction.
			State#?STATE.client ! #mqtt_pubrec{message_id=MessageId},
			Worker = proc_lib:spawn_link(?STATE, transaction_loop, [ClientId, Info, Timeout, Trace]),
			Complete = #mqtt_pubcomp{message_id=MessageId},
			noreply(State#?STATE{transactions=[{MessageId, Worker, Complete} | Transactions]});
		at_least_once ->
			% Start 1-way handshake transaction.
			Worker = proc_lib:spawn_link(?STATE, transaction_loop, [ClientId, Info, Timeout, Trace]),
			Worker ! release,
			State#?STATE.client ! #mqtt_puback{message_id=MessageId},
			noreply(State#?STATE{transactions=[{MessageId, Worker, undefined} | Transactions]});
		_ ->
			catch do_transaction(ClientId, Info, Trace),
			noreply(State)
	end;
handle_info(#mqtt_puback{message_id=MessageId}, State=#?STATE{name=ClientId}) ->
	% The message id is supposed to be in the retry pool.
	% Find and cancel the retry schedule.
	erlang:garbage_collect(),
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, _Fubar, _, Timer}, Pool} ->
			timer:cancel(Timer),
			noreply(State#?STATE{retry_pool=Pool});
		false ->
			lager:warning("~p too late puback for ~p", [ClientId, MessageId]),
			noreply(State)
	end;
handle_info(#mqtt_pubrec{message_id=MessageId}, State=#?STATE{name=ClientId, client=Client}) ->
	% The message id is supposed to be in the retry pool.
	% Find, cancel the retry schedule, send pubrel and wait for pubcomp.
	erlang:garbage_collect(),
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, Fubar, _, Timer}, Pool} ->
			timer:cancel(Timer),
			Reply = #mqtt_pubrel{message_id=MessageId},
			Client ! Reply,
			Fubar1 = fubar:set([{via, ClientId}, {payload, Reply}], Fubar),
			{ok, Timer1} = timer:send_after(#?STATE.retry_after*#?STATE.max_retries, {retry, MessageId}),
			noreply(State#?STATE{retry_pool=[{MessageId, Fubar1, #?STATE.max_retries, Timer1} | Pool]});
		false ->
			lager:warning("~p too late pubrec for ~p", [ClientId, MessageId]),
			noreply(State)
	end;
handle_info(#mqtt_pubrel{message_id=MessageId}, State=#?STATE{name=ClientId}) ->
	erlang:garbage_collect(),
	case lists:keyfind(MessageId, 1, State#?STATE.transactions) of
		false ->
			lager:warning("~p too late pubrel for ~p", [ClientId, MessageId]),
			noreply(State);
		{MessageId, Worker, _} ->
			Worker ! release,
			noreply(State)
	end;
handle_info(#mqtt_pubcomp{message_id=MessageId}, State=#?STATE{name=ClientId}) ->
	% The message id is supposed to be in the retry pool.
	% Find, cancel the retry schedule.
	erlang:garbage_collect(),
	case lists:keytake(MessageId, 1, State#?STATE.retry_pool) of
		{value, {MessageId, _Fubar, _, Timer}, Pool} ->
			timer:cancel(Timer),
			noreply(State#?STATE{retry_pool=Pool});
		false ->
			lager:warning("~p too late pubcomp for ~p", [ClientId, MessageId]),
			noreply(State)
	end;
handle_info(#mqtt_subscribe{message_id=MessageId, dup=true}, State) ->
	% Subscribe is performed synchronously.
	% Just drop duplicate requests.
	erlang:garbage_collect(),
	lager:debug("~p dropping duplicate subscribe ~p", [State#?STATE.name, MessageId]),
	noreply(State);
handle_info(Info=#mqtt_subscribe{message_id=MessageId},
			State=#?STATE{name=ClientId, transaction_timeout=Timeout, trace=Trace}) ->
	erlang:garbage_collect(),
	QoSs = do_transaction(ClientId, Info, Timeout, Trace),
	case Info#mqtt_subscribe.qos of
		at_most_once -> ok;
		_ -> State#?STATE.client ! #mqtt_suback{message_id=MessageId, qoss=QoSs}
	end,
	{Topics, _} = lists:unzip(Info#mqtt_subscribe.topics),
	F = fun({Topic, QoS}, Subscriptions) ->
				lists:keystore(Topic, 1, Subscriptions, {Topic, QoS})
		end,
	noreply(State#?STATE{subscriptions=lists:foldl(F, State#?STATE.subscriptions, lists:zip(Topics, QoSs))});
handle_info(#mqtt_unsubscribe{message_id=MessageId, dup=true}, State) ->
	% Unsubscribe is performed synchronously.
	% Just drop duplicate requests.
	erlang:garbage_collect(),
	lager:debug("~p dropping duplicate unsubscribe ~p", [State#?STATE.name, MessageId]),
	noreply(State);
handle_info(Info=#mqtt_unsubscribe{message_id=MessageId, topics=Topics},
			State=#?STATE{name=ClientId, transaction_timeout=Timeout, trace=Trace}) ->
	erlang:garbage_collect(),
	do_transaction(ClientId, Info, Timeout, Trace),
	case Info#mqtt_unsubscribe.qos of
		at_most_once -> ok;
		_ -> State#?STATE.client ! #mqtt_unsuback{message_id=MessageId}
	end,
	F = fun(Topic, Subscriptions) ->
				lists:keydelete(Topic, 1, Subscriptions)
		end,
	noreply(State#?STATE{subscriptions=lists:foldl(F, State#?STATE.subscriptions, Topics)});
handle_info({'EXIT', Client, Reason}, State=#?STATE{name=Name, client=Client,
													 message_id=MessageId, trace=Trace}) ->
	lager:debug("~p client ~p down by ~p", [State#?STATE.name, Client, Reason]),
	case State#?STATE.will of
		undefined ->
			ok;
		{WillTopic, WillMessage, WillQoS, WillRetain} ->
			NewMessageId = MessageId rem 16#ffff + 1,
			Message = mqtt:publish([{message_id, NewMessageId}, {topic, WillTopic},
									{qos, WillQoS}, {retain, WillRetain}, {payload, WillMessage}]),
			do_transaction(Name, Message, Trace)
	end,
	case State#?STATE.username of
		nil -> ok;
		Username -> mqtt_stat:leave(Username)
	end,
	noreply(State#?STATE{client=undefined, username=nil, timestamp=os:timestamp()});
handle_info({'EXIT', Worker, normal}, State=#?STATE{name=ClientId}) ->
	% Likely to be a transaction completion signal.
	case lists:keytake(Worker, 2, State#?STATE.transactions) of
		{value, {MessageId, Worker, Complete}, Rest} ->
			lager:debug("~p transaction ~p complete", [ClientId, MessageId]),
			case Complete of
				undefined -> ok;
				_ -> State#?STATE.client ! Complete
			end,
			noreply(State#?STATE{transactions=Rest});
		false ->
			lager:error("~p unknown exit normal from ~p", [ClientId, Worker]),
			noreply(State)
	end;
handle_info({'EXIT', Worker, Reason}, State=#?STATE{name=ClientId}) ->
	% Likely to be a transaction failure signal.
	case lists:keytake(Worker, 2, State#?STATE.transactions) of
		{value, {MessageId, Worker, _}, Rest} ->
			lager:error("~p transaction ~p failed by ~p", [ClientId, MessageId, Reason]),
			noreply(State#?STATE{transactions=Rest});
		false ->
			lager:error("~p unknown exit ~p from ~p", [ClientId, Reason, Worker]),
			noreply(State)
	end;

handle_info(timeout, State=#?STATE{name=Name}) ->
	% Session timeout by client offline.
	lager:info("~p timed out", [Name]),
	{stop, normal, State};

%% Fallback
handle_info(Info, State) ->
	lager:warning("~p unknown info ~p", [State#?STATE.name, Info]),
	noreply(State).

terminate(Reason, State=#?STATE{name=Name}) ->
	lager:notice("session ~p terminate by ~p", [Name, Reason]),
	mqtt_stat:leave(sessions),
	case State#?STATE.username of
		nil -> ok;
		Username -> mqtt_stat:leave(Username)
	end,
	handle_cast(clean, State),
	fubar_route:clean(Name).

code_change(OldVsn, State, Extra) ->
	lager:debug("code change from ~p while ~p, ~p", [OldVsn, State, Extra]),
	{ok, State}.

handle_alert(Session, true) ->
	gen_server:cast(Session, {alert, true});
handle_alert(Session, false) ->
	gen_server:cast(Session, {alert, false}).

transaction_loop(ClientId, Message, Timeout, Trace) ->
	lager:debug("~p transaction ~p open", [ClientId, mqtt:message_id(Message)]),
	receive
		release ->
			lager:debug("~p transaction ~p released", [ClientId, mqtt:message_id(Message)]),
			% Async transaction is enough even if the transaction itself should be sync.
			do_transaction(ClientId, Message, Trace)
		after Timeout ->
			exit(timeout)
	end.

%%
%% Local
%%
reply(Reply, State=#?STATE{client=undefined, timestamp=T, max_age=MaxAge}) ->
	Age = timer:now_diff(os:timestamp(), T) div 1000,
	{reply, Reply, State, max(MaxAge-Age, 0)};
reply(Reply, State) ->
	{reply, Reply, State}.

noreply(State=#?STATE{client=undefined, timestamp=T, max_age=MaxAge}) ->
	Age = timer:now_diff(os:timestamp(), T) div 1000,
	{noreply, State, max(MaxAge-Age, 0)};
noreply(State) ->
	{noreply, State}.
	
do_transaction(ClientId, Message=#mqtt_publish{topic=Name}, Trace) ->
	Props = [{from, ClientId}, {to, Name}, {via, undefined}, {payload, Message}],
	case fubar_route:resolve(Name) of
		{ok, {undefined, mqtt_topic, Trace1}} ->
			Fubar = case Trace or Trace1 of
						true -> fubar:create([{id, uuid:get_v4()} | Props]);
						_ -> fubar:create(Props)
					end,
			case mqtt_topic:start([{name, Name}, {trace, Trace1}]) of
				{ok, Topic} ->
					case gen_server:cast(Topic, Fubar) of
						ok -> ok;
						Error2 -> exit(Error2)
					end;
				Error3 ->
					exit(Error3)
			end;
		{ok, {undefined, _, _}} ->
			lager:warning("~p session down, publish abort", [Name]),
			exit(normal);
		{ok, {Pid, _, Trace1}} ->
			Fubar = case Trace or Trace1 of
						true -> fubar:create([{id, uuid:get_v4()} | Props]);
						_ -> fubar:create(Props)
					end,
			Node = node(),
			case catch node(Pid) of
				Node ->
					ok;
				OtherNode ->
					lager:info("~p publishes to ~p at remote ~p", [ClientId, Name, OtherNode])
			end,
			gen_server:cast(Pid, Fubar);
		{error, not_found} ->
			lager:warning("~p no such route, publish abort", [Name]),
			exit(normal);
		Error ->
			exit(Error)
	end.

do_transaction(ClientId, #mqtt_subscribe{topics=Topics}, _Timeout, Trace) ->
	F = fun({Topic, QoS}) ->
			Props = [{from, ClientId}, {to, Topic},
					 {via, undefined}, {payload, {subscribe, QoS, ?MODULE, self()}}],
			case fubar_route:ensure(Topic, mqtt_topic) of
				{ok, {Pid, _, Trace1}} ->
					Fubar = case Trace or Trace1 of
								true -> fubar:create([{id, uuid:get_v4()} | Props]);
								_ -> fubar:create(Props)
							end,
					catch gen_server:cast(Pid, Fubar),
					QoS;
				_ ->
					undefined
			end
		end,
	lists:map(F, Topics);
do_transaction(ClientId, #mqtt_unsubscribe{topics=Topics}, _Timeout, Trace) ->
	F = fun(Topic) ->
			Props = [{from, ClientId}, {to, Topic},
					 {via, undefined}, {payload, unsubscribe}],
			case fubar_route:resolve(Topic) of
				{ok, {Pid, mqtt_topic, Trace1}} ->
					Fubar = case Trace or Trace1 of
								true -> fubar:create([{id, uuid:get_v4()} | Props]);
								_ -> fubar:create(Props)
							end,
					catch gen_server:cast(Pid, Fubar);
				_ ->
					{error, not_found}
			end
		end,
	lists:foreach(F, Topics).

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
