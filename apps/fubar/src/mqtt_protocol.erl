%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT protocol parser.
%%%   mqtt_protocol is designed to run under ranch as server or
%%% independently as client also.  In server mode, ranch_conns_sup
%%% calls mqtt_protocol:start_link/4 callback.  For client mode,
%%% mqtt_protocol:start/1 is provided.  Either way, it runs as a
%%% gen_server.
%%%   It receives tcp data from a socket and parses to make mqtt
%%% messages and hand them over to a dispatcher behind.  A dispatcher
%%% must implement mqtt_protocol callback behavior.
%%%
%%% Created : Nov 14, 2012
%%% Refactored : Jan 16, 2014
%%% -------------------------------------------------------------------
-module(mqtt_protocol).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).
-behavior(ranch_protocol).

%%
%% Exports
%%
-export([start/1, stop/1, setopts/2]).

%%
%% Callbacks
%%
-export([start_link/4, server_init/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

%%
%% mqtt_protocol behavior callback definition
%%
-callback init(Context :: term()) ->
		{reply, mqtt_message(), NewContext :: term(), timeout()} |
		{noreply, NewContext :: term(), timeout()} |
		{stop, Reason :: term()}.

-callback handle_message(mqtt_message(), Context :: term()) ->
		{reply, mqtt_message(), NewContext :: term(), timeout()} |
		{noreply, NewContext :: term(), timeout()} |
		{stop, Reason :: term()}.

-callback handle_event(Event :: term(), Context :: term()) ->
		{reply, mqtt_message(), NewContext :: term(), timeout()} |
		{noreply, NewContext :: term(), timeout()} |
		{stop, Reason :: term()}.
		
-callback terminate(Reason :: term(), Context :: term()) ->
		Reason :: term().

%%
%% gen_server state
%%
-define(STATE, ?MODULE).

-record(?STATE, {
		host = "localhost" :: string(),			% for client mode
		port = 1883 :: ipport(),				% for client mode
		listener :: undefined | socket(),		% for server mode
		transport = ranch_tcp :: module(),
		socket :: socket(),
		socket_options = [] :: params(),
		acl_socket_options = [] :: params(),
		max_packet_size = 4096 :: pos_integer(),
		dispatch = mqtt_server :: module(),
		context = [] :: term(),
		header,
		buffer = <<>> :: binary(),
		timeout = 10000 :: timeout()
}).

%% @doc Start mqtt_protocol in standalone gen_server.
%% Settings should be given as a parameter -- the application setting doesn't apply.
-spec start(params()) -> {ok, pid()} | {error, Reason :: term()}.
start(Params) ->
	State = ?PROPS_TO_RECORD(Params, ?STATE),
	gen_server:start(?MODULE, State#?STATE{context=Params}, []).

%% @doc Stop mqtt_protocol.
-spec stop(pid()) -> ok.
stop(Pid) ->
	gen_server:cast(Pid, stop).

%% @doc Set socket options.
-spec setopts(pid(), params()) -> ok.
setopts(Pid, Options) ->
	gen_server:cast(Pid, {setopts, Options}).


%% Standalone mode gen_server callback.
init(State) ->
	% Timeout immediately to trigger actual init asynchronously.
	{ok, State, 0}.

%% Actually called by async init, handle_info(timeout, _)
client_init(State=#?STATE{transport=T, socket=S, socket_options=O,
					dispatch=D, context=C}) ->
	T:setopts(S, O),
	case D:init(C) of
		{reply, Reply, Context, Timeout} ->
			case catch T:send(S, format(Reply)) of
				ok ->
					T:setopts(S, [{active, once}]),
					{noreply, State#?STATE{context=Context, timeout=Timeout}, Timeout};
				Error ->
					lager:warning("socket error ~p", [Error]),
					D:terminate(Error, Context),
					exit(Error)
			end;
		{noreply, Context, Timeout} ->
			T:setopts(S, [{active, once}]),
			{noreply, State#?STATE{context=Context, timeout=Timeout}, Timeout};
		{stop, Reason} ->
			{stop, Reason}
	end.

%% ranch_conns_sup calls this callback function
start_link(L, S, T, O) ->
	% Apply settings from the application metadata.
	Settings = fubar:settings(?MODULE),
	State = ?PROPS_TO_RECORD(Settings++O, ?STATE),
	proc_lib:start_link(?MODULE, server_init,
				[State#?STATE{listener=L, socket=S, transport=T}]).

server_init(State=#?STATE{listener=L, transport=T, socket=S, socket_options=O}) ->
	% proc_lib sync requirement for start_link
	ok = proc_lib:init_ack({ok, self()}),
	% ranch sync requirement for socket ownership
	% Must be called before doing anything with the socket
	ok = ranch:accept_ack(L),
	% Leave connection log
	Addr = case T:peername(S) of
			   {ok, {PeerAddr, PeerPort}} ->
				   lager:info("connection established from ~p:~p", [PeerAddr, PeerPort]),
				   PeerAddr;
			   {error, Reason} ->
				   lager:warning("failed getting peername with ~p", [Reason]),
				   undefined
		   end,
	% SSL handshake if necessary
	case S of
		{sslsocket, _, _} ->
			lager:debug("ssl info ~p", [ssl:connection_info(S)]),
			% Remove options for ssl only
			O1 = lists:foldl(	fun(Key, Acc) ->
									proplists:delete(Key, Acc)
								end, O, ssl_options()),
			State1 = State#?MODULE{socket_options=O1},
			case ssl:peercert(S) of
				{ok, _} ->
					server_init(State1, {check_addr, Addr});
				Error ->
					case proplists:get_value(verify, O) of
						verify_peer ->
							% The client is not certified and rejected.
							lager:warning("ssl cert rejected by ~p", [Error]),
							exit(normal);
						_ ->
							% The client is not certified but accepted.
							server_init(State1, {check_addr, Addr})
					end
			end;
		_ ->
			server_init(State, {check_addr, Addr})
	end.

server_init(State=#?STATE{acl_socket_options=O}, {check_addr, Addr}) ->
	case mqtt_acl:verify(Addr) of
		ok ->
			lager:info("acl pass from ~p", [Addr]),
			% Change socket options for privileged and bypass auth.
			server_init(State#?STATE{socket_options=O, context=[{auth, undefined}]}, ok);
		{error, not_found} ->
			server_init(State, ok);
		{error, forbidden} ->
			lager:info("acl block from ~p", [Addr]),
			exit(normal)
	end;
server_init(State=#?STATE{transport=T, socket=S, socket_options=O,
					dispatch=D, context=C}, ok) ->
	ok = T:setopts(S, O),
	case D:init(C) of
		{reply, Reply, Context, Timeout} ->
			% If there is a server initiated message
			Data = format(Reply),
			lager:debug("STREAM OUT ~p", [Data]),
			case catch T:send(S, Data) of
				ok ->
					process_flag(trap_exit, true),
					mqtt_stat:join(connections),
					T:setopts(S, [{active, once}]),
					gen_server:enter_loop(?MODULE, [], State#?STATE{context=Context, timeout=Timeout}, Timeout);
				{error, Reason} ->
					lager:warning("socket error ~p", [Reason]),
					D:terminate(Reason, Context),
					exit(normal);
				Exit ->
					lager:warning("socket exception ~p", [Exit]),
					D:terminate(Exit, Context),
					exit(normal)
			end;
		{noreply, Context, Timeout} ->
			process_flag(trap_exit, true),
			mqtt_stat:join(connections),
			T:setopts(S, [{active, once}]),
			gen_server:enter_loop(?MODULE, [], State#?STATE{context=Context, timeout=Timeout}, Timeout);
		{stop, Reason} ->
			lager:debug("dispatch init failure ~p", [Reason]),
			exit(normal)
	end.

%% Fallback
handle_call(M, F, State=#?STATE{timeout=T}) ->
	lager:warning("unknown call ~p from ~p", [M, F]),
	{reply, {error, unknown}, State, T}.

%% Async administrative commands.
handle_cast({send, M}, State=#?STATE{transport=T, socket=S,
								dispatch=D, context=C, timeout=T}) ->
	Data = format(M),
	lager:debug("STREAM OUT: ~p", [Data]),
	case catch T:send(S, Data) of
		ok ->
			{noreply, State, T};
		{error, Reason} ->
			lager:warning("socket error ~p", [Reason]),
			{stop, D:terminate(M, C), State};
		Exit ->
			lager:warning("socket exception ~p", [Exit]),
			{stop, D:terminate(M, C), State}
	end;
handle_cast(stop, State=#?STATE{dispatch=D, context=C}) ->
	{stop, D:terminate(normal, C), State};

%% Fallback
handle_cast(M, State=#?STATE{timeout=T}) ->
	lager:warning("unknown cast ~p", [M]),
	{noreply, State, T}.

%% Apply socket options.
handle_info({setopts, O}, State=#?STATE{transport=T, socket=S, timeout=T}) ->
	lager:debug("setopts ~p", [O]),
	T:setopts(S, [{active, once} | O]),
	{noreply, State, T};

%% Standalone mode async init from init/1
handle_info(timeout, State=#?STATE{transport=T, socket=undefined, socket_options=O}) ->
	case catch T:connect(State#?STATE.host, State#?STATE.port, O) of
		{ok, Socket} ->
			{ok, {Addr, Port}} = T:peername(Socket),
			lager:info("connection established to ~p:~p", [Addr, Port]),
			case Socket of
				{sslsocket, _, _} ->
					lager:debug("ssl info: ~p", [ssl:connection_info(Socket)]),
					case ssl:peercert(Socket) of
						{ok, _} ->
							client_init(State#?STATE{
											socket=Socket,
											socket_options=lists:foldl(	fun(Key, Acc) ->
																			proplists:delete(Key, Acc)
																		end, O, ssl_options())
										});
						Error ->
							{stop, Error}
					end;
				_ ->
					client_init(State#?STATE{socket=Socket})
			end;
		Error1 ->
			{stop, Error1}
	end;

%% Received tcp data, start parsing.
handle_info({ssl, S, P}, State=#?STATE{socket=S}) ->
	handle_info({tcp, S, P}, State);
handle_info({tcp, S, P}, State=#?STATE{transport=T, socket=S, buffer=B,
								dispatch=D, context=C}) ->
	erlang:garbage_collect(),
	case P of
		<<>> -> ok; % empty packet
		_ -> lager:debug("STREAM IN ~p", [P])
	end,
	% Append the packet at the end of the buffer and start parsing.
	case parse(State#?STATE{buffer= <<B/binary, P/binary>>}) of
		{ok, Message, State1} ->
			% Parsed one message.
			% Call dispatcher.
			case D:handle_message(Message, C) of
				{reply, Reply, Context, Timeout} ->
					P1 = format(Reply),
					lager:debug("STREAM OUT ~p", [P1]),
					case catch T:send(S, P1) of
						ok ->
							% Simulate new tcp data to trigger next parsing schedule.
							self() ! {tcp, S, <<>>},
							{noreply, State1#?STATE{context=Context, timeout=Timeout}, Timeout};
						{error, Reason} ->
							lager:warning("socket error ~p", [Reason]),
							{stop, D:terminate(Reply, Context), State1#?STATE{context=Context}};
						Exit ->
							lager:warning("socket exception ~p", [Exit]),
							{stop, D:terminate(Reply, Context), State1#?STATE{context=Context}}
					end;
				{noreply, Context, Timeout} ->
					self() ! {tcp, S, <<>>},
					{noreply, State1#?STATE{context=Context, timeout=Timeout}, Timeout};
				{stop, Reason, Context} ->
					lager:debug("dispatch issued stop ~p", [Reason]),
					{stop, D:terminate(Reason, Context), State1#?STATE{context=Context}}
			end;
		{more, State1} ->
			% The socket gets active after consuming previous data.
			T:setopts(S, [{active, once}]),
			{noreply, State1, State#?STATE.timeout};
		{error, Reason, State1} ->
			lager:warning("parse error ~p", [Reason]),
			{stop, D:terminate(normal, C), State1}
	end;

%% Socket close detected.
handle_info({ssl_closed, S}, State=#?STATE{socket=S}) ->
	handle_info({tcp_closed, S}, State);
handle_info({tcp_closed, S}, State=#?STATE{transport=T, socket=S, dispatch=D, context=C}) ->
	T:close(S),
	{stop, D:terminate(normal, C), State#?STATE{socket=undefined}};

%% Socket error detected.
handle_info({ssl_error, S, R}, State=#?STATE{socket=S, dispatch=D, context=C}) ->
	lager:warning("ssl error ~p", [R]),
	{stop, D:terminate(normal, C), State};
handle_info({tcp_error, S, R}, State=#?STATE{socket=S, dispatch=D, context=C}) ->
	lager:warning("tcp error ~p", [R]),
	{stop, D:terminate(normal, C), State};

%% Trap exit
handle_info({'EXIT', F, R}, State=#?STATE{dispatch=D, context=C}) ->
	lager:warning("trap exit ~p from ~p", [R, F]),
	{stop, D:terminate(normal, C), State};

%% Invoke dispatcher to handle all the other events.
handle_info(M, State=#?STATE{transport=T, socket=S, dispatch=D, context=C}) ->
	case D:handle_event(M, C) of
		{reply, Reply, Context, Timeout} ->
			Data = format(Reply),
			lager:debug("STREAM OUT ~p", [Data]),
			case catch T:send(S, Data) of
				ok ->
					{noreply, State#?STATE{context=Context, timeout=Timeout}, Timeout};
				{error, Reason} ->
					lager:warning("~p:send/1 error ~p", [T, Reason]),
					{stop, D:terminate(Reply, Context), State#?STATE{context=Context}};
				Exit ->
					lager:warning("~p:send/1 exception ~p", [T, Exit]),
					{stop, D:terminate(Reply, Context), State#?STATE{context=Context}}
			end;
		{noreply, Context, Timeout} ->
			{noreply, State#?STATE{context=Context, timeout=Timeout}, Timeout};
		{stop, Reason, Context} ->
			lager:debug("dispatch issued stop ~p", [Reason]),
			{stop, D:terminate(normal, Context), State#?STATE{context=Context}}
	end.

%% Termination logic.
terminate(R, State=#?STATE{transport=T}) ->
	case State#?STATE.listener of
		undefined -> ok;
		_ ->  mqtt_stat:leave(connections)
	end,
	case State#?STATE.socket of
		undefined ->
			lager:info("~p closed by ~p", [T, R]);
		Socket ->
			lager:info("closing ~p by ~p", [T, R]),
			T:close(Socket)
	end.

code_change(V, State, Ex) ->
	lager:debug("code change from ~p while ~p, ~p", [V, State, Ex]),
	{ok, State}.

%%
%% Local functions
%%
parse(State=#?STATE{header=undefined, buffer= <<>>}) ->
	% Not enough data to start parsing.
	{more, State};
parse(State=#?STATE{header=undefined, buffer=B}) ->
	% Read fixed header part and go on.
	{Fixed, Rest} = read_fixed_header(B),
	parse(State#?STATE{header=Fixed, buffer=Rest});
parse(State=#?STATE{header=H, buffer=B, max_packet_size=M})
  when H#mqtt_header.size =:= undefined ->
	% Read size part.
	case decode_number(B) of
		{ok, N, Payload} ->
			H1 = H#mqtt_header{size=N},
			case N of
				_ when M < N+2 ->
					{error, overflow, State#?STATE{header=H1}};
				_ ->
					parse(State#?STATE{header=H1, buffer=Payload})
			end;
		more when M < size(B)+1 ->
			{error, overflow, State};
		more ->
			{more, State};
		{error, Reason} ->
			{error, Reason, State}
	end;
parse(State=#?STATE{header=H, buffer=B})
  when size(B) >= H#mqtt_header.size ->
	% Ready to read payload.
	case catch read_payload(H, B) of
		{ok, Msg, Rest} ->
			% Copy the buffer to prevent the binary from increasing indefinitely.
			{ok, Msg, State#?STATE{header=undefined, buffer=Rest}};
		{'EXIT', From, Reason} ->
			{error, {'EXIT', From, Reason}}
	end;
parse(State) ->
	{more, State}.

decode_number(B) ->
	split_number(B, <<>>).

split_number(<<>>, _) ->
	more;
split_number(<<1:1/unsigned, N:7/bitstring, Rest/binary>>, B) ->
	split_number(Rest, <<B/binary, 0:1, N/bitstring>>);
split_number(<<N:8/bitstring, Rest/binary>>, B) ->
	{ok, read_number(<<B/binary, N/bitstring>>), Rest}.

read_number(<<>>) ->
	0;
read_number(<<N:8/big, T/binary>>) ->
	N + 128*read_number(T).

read_fixed_header(B) ->
	<<Type:4/big-unsigned, Dup:1/unsigned,
	  QoS:2/big-unsigned, Retain:1/unsigned,
	  Rest/binary>> = B,
	{#mqtt_header{type=case Type of
						   0 -> mqtt_reserved;
						   1 -> mqtt_connect;
						   2 -> mqtt_connack;
						   3 -> mqtt_publish;
						   4 -> mqtt_puback;
						   5 -> mqtt_pubrec;
						   6 -> mqtt_pubrel;
						   7 -> mqtt_pubcomp;
						   8 -> mqtt_subscribe;
						   9 -> mqtt_suback;
						   10 -> mqtt_unsubscribe;
						   11 -> mqtt_unsuback;
						   12 -> mqtt_pingreq;
						   13 -> mqtt_pingresp;
						   14 -> mqtt_disconnect;
						   _ -> undefined
					   end,
				  dup=(Dup =/= 0),
				  qos=case QoS of
						  0 -> at_most_once;
						  1 -> at_least_once;
						  2 -> exactly_once;
						  _ -> undefined
					  end,
				  retain=(Retain =/= 0)}, Rest}.

read_payload(H=#mqtt_header{type=T, size=S}, B) ->
	% Need to split a payload first.
	<<Payload:S/binary, Rest/binary>> = B,
	Msg = 	case T of
				mqtt_reserved ->
					read_reserved(H, binary:copy(Payload));
				mqtt_connect ->
					read_connect(H, binary:copy(Payload));
				mqtt_connack ->
					read_connack(H, binary:copy(Payload));
				mqtt_publish ->
					read_publish(H, binary:copy(Payload));
				mqtt_puback ->
					read_puback(H, binary:copy(Payload));
				mqtt_pubrec ->
					read_pubrec(H, binary:copy(Payload));
				mqtt_pubrel ->
					read_pubrel(H, binary:copy(Payload));
				mqtt_pubcomp ->
					read_pubcomp(H, binary:copy(Payload));
				mqtt_subscribe ->
					read_subscribe(H, binary:copy(Payload));
				mqtt_suback ->
					read_suback(H, binary:copy(Payload));
				mqtt_unsubscribe ->
					read_unsubscribe(H, binary:copy(Payload));
				mqtt_unsuback ->
					read_unsuback(H, binary:copy(Payload));
				mqtt_pingreq ->
					read_pingreq(H, binary:copy(Payload));
				mqtt_pingresp ->
					read_pingresp(H, binary:copy(Payload));
				mqtt_disconnect ->
					read_disconnect(H, binary:copy(Payload));
				_ ->
					undefined
			end,
	{ok, Msg, binary:copy(Rest)}.

read_connect(_Header,
			 <<ProtocolLength:16/big-unsigned, Protocol:ProtocolLength/binary,
			   Version:8/big-unsigned, UsernameFlag:1/unsigned, PasswordFlag:1/unsigned,
			   WillRetain:1/unsigned, WillQoS:2/big-unsigned, WillFlag:1/unsigned,
			   CleanSession:1/unsigned, MaxRecursionFlag:1/unsigned, KeepAlive:16/big-unsigned,
			   ClientIdLength:16/big-unsigned, ClientId:ClientIdLength/binary, Rest/binary>>) ->
	{WillTopic, WillMessage, Rest1} = case WillFlag of
										  0 ->
											  {undefined, undefined, Rest};
										  _ ->
											  <<WillTopicLength:16/big-unsigned, WillTopic_:WillTopicLength/binary,
												WillMessageLength:16/big-unsigned, WillMessage_:WillMessageLength/binary, Rest1_/binary>> = Rest,
											  {WillTopic_, WillMessage_, Rest1_}
									  end,
	{Username, Rest2} = case UsernameFlag of
							0 ->
								{<<>>, Rest1};
							_ ->
								<<UsernameLength:16/big-unsigned, Username_:UsernameLength/binary, Rest2_/binary>> = Rest1,
								{Username_, Rest2_}
						end,
	{Password, Rest3} = case PasswordFlag of
							 0 ->
								 {<<>>, Rest2};
							 _ ->
								 <<PasswordLength:16/big-unsigned, Password_:PasswordLength/binary, Rest3_/binary>> = Rest2,
								 {Password_, Rest3_}
						end,
	{MaxRecursion, Rest4} = case MaxRecursionFlag of
								0 ->
									{0, Rest3};
								_ ->
									<<MaxRecursion_:16/big-unsigned, Rest4_/binary>> = Rest3,
									{MaxRecursion_, Rest4_}
							end,
	#mqtt_connect{protocol=Protocol,
				  version=Version,
				  username=Username,
				  password=Password,
				  will_retain=(WillRetain =/= 0),
				  will_qos=case WillQoS of
							   0 -> at_most_once;
							   1 -> at_least_once;
							   2 -> exactly_once;
							   _ -> undefined
						   end,
				  will_topic=WillTopic,
				  will_message=WillMessage,
				  clean_session=(CleanSession =/= 0),
				  keep_alive=case KeepAlive of
								 0 -> infinity;
								 _ -> KeepAlive
							 end,
				  client_id=ClientId,
				  max_recursion = MaxRecursion,
				  extra=Rest4}.
	
read_connack(_Header,
			 <<_Reserved:8/big-unsigned, Code:8/big-unsigned, Rest/binary>>) ->
	{AltServer, MaxRecursion, Rest1} = case Code of
										   6 -> % new alt server response
										  	   <<Length:16/big-unsigned, AltServer_:Length/binary, MaxRecur_:16/big-unsigned, Rest1_/binary>> = Rest,
										  	   {AltServer_, MaxRecur_, Rest1_};
										   _ ->
										   	   {<<>>, 0, Rest}
									   end,
	#mqtt_connack{code=case Code of
						   0 -> accepted;
						   1 -> incompatible;
						   2 -> id_rejected;
						   3 -> unavailable;
						   4 -> forbidden;
						   5 -> unauthorized;
						   6 -> alt_server;
						   _ -> undefined
					   end,
				  alt_server=AltServer,
				  max_recursion=MaxRecursion,
				  extra=Rest1}.

read_publish(#mqtt_header{dup=Dup, qos=QoS, retain=Retain},
			 <<TopicLength:16/big-unsigned, Topic:TopicLength/binary, Rest/binary>>) ->
	{MessageId, Rest1} = case QoS of
							 undefined ->
								 {undefined, Rest};
							 at_most_once ->
								 {undefined, Rest};
							 _ ->
								 <<MessageId_:16/big-unsigned, Rest1_/binary>> = Rest,
								 {MessageId_, Rest1_}
						 end,
	#mqtt_publish{topic=Topic,
				  message_id=MessageId,
				  payload=Rest1,
				  dup=Dup,
				  qos=QoS,
				  retain=Retain}.

read_puback(_Header, <<MessageId:16/big-unsigned, Rest/binary>>) ->
	#mqtt_puback{message_id=MessageId,
				 extra=Rest}.

read_pubrec(_Header, <<MessageId:16/big-unsigned, Rest/binary>>) ->
	#mqtt_pubrec{message_id=MessageId,
				 extra=Rest}.

read_pubrel(_Header, <<MessageId:16/big-unsigned, Rest/binary>>) ->
	#mqtt_pubrel{message_id=MessageId,
				 extra=Rest}.

read_pubcomp(_Header, <<MessageId:16/big-unsigned, Rest/binary>>) ->
	#mqtt_pubcomp{message_id=MessageId,
				  extra=Rest}.

read_subscribe(#mqtt_header{dup=Dup, qos=QoS}, Rest) ->
	{MessageId, Rest1} = case QoS of
							 undefined ->
								 {undefined, Rest};
							 at_most_once ->
								 {undefined, Rest};
							 _ ->
								 <<MessageId_:16/big-unsigned, Rest1_/binary>> = Rest,
								 {MessageId_, Rest1_}
						 end,
	{Topics, Rest2} = read_topic_qoss(Rest1, []),
	#mqtt_subscribe{message_id=MessageId,
					topics=Topics,
					dup=Dup,
					qos=QoS,
					extra=Rest2}.

read_topic_qoss(<<Length:16/big-unsigned, Topic:Length/binary, QoS:8/big-unsigned, Rest/binary>>, Topics) ->
	read_topic_qoss(Rest, Topics ++ [{Topic, case QoS of
											 0 -> at_most_once;
											 1 -> at_least_once;
											 2 -> exactly_once;
											 _ -> undefined
										 end}]);
read_topic_qoss(Rest, Topics) ->
	{Topics, Rest}.

read_suback(_Header, <<MessageId:16/big-unsigned, Rest/binary>>) ->
	QoSs = read_qoss(Rest, []),
	#mqtt_suback{message_id=MessageId,
				 qoss=QoSs}.

read_qoss(<<QoS:8/big-unsigned, Rest/binary>>, QoSs) ->
	read_qoss(Rest, QoSs ++ [case QoS of
								 0 -> at_most_once;
								 1 -> at_least_once;
								 2 -> exactly_once;
								 _ -> undefined
							 end]);
read_qoss(_, QoSs) ->
	QoSs.

read_unsubscribe(#mqtt_header{dup=Dup, qos=QoS}, Rest) ->
	{MessageId, Rest1} = case QoS of
							 undefined ->
								 {undefined, Rest};
							 at_most_once ->
								 {undefined, Rest};
							 _ ->
								 <<MessageId_:16/big-unsigned, Rest1_/binary>> = Rest,
								 {MessageId_, Rest1_}
						 end,
	{Topics, Rest2} = read_topics(Rest1, []),
	#mqtt_unsubscribe{message_id=MessageId,
					  topics=Topics,
					  dup=Dup,
					  qos=QoS,
					  extra=Rest2}.

read_topics(<<Length:16/big-unsigned, Topic:Length/binary, Rest/binary>>, Topics) ->
	read_topics(Rest, Topics ++ [Topic]);
read_topics(Rest, Topics) ->
	{Topics, Rest}.

read_unsuback(_Header, <<MessageId:16/big-unsigned, Rest/binary>>) ->
	#mqtt_unsuback{message_id=MessageId,
				   extra=Rest}.

read_pingreq(_Header, Rest) ->
	#mqtt_pingreq{extra=Rest}.

read_pingresp(_Header, Rest) ->
	#mqtt_pingresp{extra=Rest}.

read_disconnect(_Header, Rest) ->
	#mqtt_disconnect{extra=Rest}.

read_reserved(#mqtt_header{dup=Dup, qos=QoS, retain=Retain}, Rest) ->
	#mqtt_reserved{dup=Dup,
				   qos=QoS,
				   retain=Retain,
				   extra=Rest}.

format(true) ->
	<<1:1/unsigned>>;
format(false) ->
	<<0:1>>;
format(Binary) when is_binary(Binary) ->
	Length = size(Binary),
	<<Length:16/big-unsigned, Binary/binary>>;
format(at_most_once) ->
	<<0:2>>;
format(at_least_once) ->
	<<1:2/big-unsigned>>;
format(exactly_once) ->
	<<2:2/big-unsigned>>;
format(undefined) ->
	<<3:2/big-unsigned>>;
format(N) when is_integer(N) ->
	<<N:16/big-unsigned>>;
format(#mqtt_connect{protocol=Protocol, version=Version, username=Username,
					 password=Password, will_retain=WillRetain, will_qos=WillQoS,
					 will_topic=WillTopic, will_message=WillMessage,
					 clean_session=CleanSession, keep_alive=KeepAlive, client_id=ClientId,
					 max_recursion=MaxRecursion, extra=Extra}) ->
	ProtocolField = format(Protocol),
	{UsernameFlag, UsernameField} = case Username of
										nil ->
											{<<0:1>>, <<>>};
										<<>> ->
											{<<0:1>>, <<>>};
										_ ->
											{<<1:1/unsigned>>, format(Username)}
									end,
	{PasswordFlag, PasswordField} = case Password of
										undefined ->
											{<<0:1>>, <<>>};
										<<>> ->
											{<<0:1>>, <<>>};
										_ ->
											{<<1:1/unsigned>>, format(Password)}
									end,
	{WillRetainFlag, WillQoSFlag, WillFlag, WillTopicField, WillMessageField} =
		case WillTopic of
			undefined ->
				{<<0:1>>, <<0:2>>, <<0:1>>, <<>>, <<>>};
			_ ->
				{format(WillRetain), format(WillQoS), <<1:1/unsigned>>, format(WillTopic), format(WillMessage)}
		end,
	CleanSessionFlag = format(CleanSession),
	{MaxRecursionFlag, MaxRecursionField} = case MaxRecursion of
												_ when MaxRecursion > 0 ->
													{<<1:1/unsigned>>, <<MaxRecursion:16/big-unsigned>>};
												_ ->
													{<<0:1/unsigned>>, <<>>}
											end,
	KeepAliveValue = case KeepAlive of
						 infinity -> 0;
						 _ -> KeepAlive
					 end,
	ClientIdField = format(ClientId),
	Payload = <<ProtocolField/binary, Version:8/big-unsigned, UsernameFlag/bitstring,
				PasswordFlag/bitstring, WillRetainFlag/bitstring, WillQoSFlag/bitstring,
				WillFlag/bitstring, CleanSessionFlag/bitstring, MaxRecursionFlag/bitstring,
				KeepAliveValue:16/big-unsigned, ClientIdField/binary,
				WillTopicField/binary, WillMessageField/binary,
				UsernameField/binary, PasswordField/binary, MaxRecursionField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<1:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_connack{code=Code, alt_server=AltServer, max_recursion=MaxRecursion, extra=Extra}) ->
	{CodeField, Extra1} = case Code of
							  accepted -> {<<0:8/big-unsigned>>, Extra};
							  incompatible -> {<<1:8/big-unsigned>>, Extra};
							  id_rejected -> {<<2:8/big-unsigned>>, Extra};
							  unavailable -> {<<3:8/big-unsigned>>, Extra};
							  forbidden -> {<<4:8/big-unsigned>>, Extra};
							  unauthorized -> {<<5:8/big-unsigned>>, Extra};
							  alt_server ->
							  	  AltServerField = format(AltServer),
							  	  {<<6:8/big-unsigned>>, <<AltServerField/binary, MaxRecursion:16/big-unsigned, Extra/binary>>};
							  _ -> {<<255:8/big-unsigned>>, Extra}
						  end,
	Payload = <<0:8, CodeField/bitstring, Extra1/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<2:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_publish{topic=Topic, message_id=MessageId, payload=PayloadField, dup=Dup, qos=QoS,
					 retain=Retain}) ->
	DupFlag = format(Dup),
	QoSFlag = format(QoS),
	RetainFlag = format(Retain),
	TopicField = format(Topic),
	MessageIdField = case QoS of
						 at_most_once -> <<>>;
						 _ -> format(MessageId)
					 end,
	Payload = <<TopicField/binary, MessageIdField/binary, PayloadField/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<3:4/big-unsigned, DupFlag/bitstring, QoSFlag/bitstring, RetainFlag/bitstring,
	  PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_puback{message_id=MessageId, extra=Extra}) ->
	MessageIdField = format(MessageId),
	Payload = <<MessageIdField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<4:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_pubrec{message_id=MessageId, extra=Extra}) ->
	MessageIdField = format(MessageId),
	Payload = <<MessageIdField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<5:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_pubrel{message_id=MessageId, extra=Extra}) ->
	MessageIdField = format(MessageId),
	Payload = <<MessageIdField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<6:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_pubcomp{message_id=MessageId, extra=Extra}) ->
	MessageIdField = format(MessageId),
	Payload = <<MessageIdField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<7:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_subscribe{message_id=MessageId, topics=Topics, dup=Dup, qos=QoS, extra=Extra}) when is_list(Topics) ->
	MessageIdField = case QoS of
						 at_most_once -> <<>>;
						 _ -> format(MessageId)
					 end,
	TopicsField = lists:foldl(fun(Spec, Acc) ->
									  {Topic, Q} = case Spec of
													   {K, V} -> {K, V};
													   K -> {K, exactly_once}
												   end,
									  TopicField = format(Topic),
									  QoSField = format(Q),
									  <<Acc/binary, TopicField/binary, 0:6, QoSField/bitstring>>
							  end, <<>>, Topics),
	DupFlag = format(Dup),
	QoSFlag = format(QoS),
	Payload = <<MessageIdField/binary, TopicsField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<8:4/big-unsigned, DupFlag/bitstring, QoSFlag/bitstring, 0:1,
	  PayloadLengthField/binary, Payload/binary>>;
format(Message=#mqtt_subscribe{topics=Topic}) ->
	format(Message#mqtt_subscribe{topics=[Topic]});
format(#mqtt_suback{message_id=MessageId, qoss=QoSs}) ->
	MessageIdField = format(MessageId),
	QoSsField = lists:foldl(fun(QoS, Acc) ->
									QoSField = format(QoS),
									<<Acc/binary, 0:6, QoSField/bitstring>>
							end, <<>>, QoSs),
	Payload = <<MessageIdField/binary, QoSsField/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<9:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_unsubscribe{message_id=MessageId, topics=Topics, dup=Dup, qos=QoS, extra=Extra}) when is_list(Topics) ->
	MessageIdField = case QoS of
						 at_most_once -> <<>>;
						 _ -> format(MessageId)
					 end,
	TopicsField = lists:foldl(fun(Topic, Acc) ->
									  TopicField = format(Topic),
									  <<Acc/binary, TopicField/binary>>
							  end, <<>>, Topics),
	DupFlag = format(Dup),
	QoSFlag = format(QoS),
	Payload = <<MessageIdField/binary, TopicsField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<10:4/big-unsigned, DupFlag/bitstring, QoSFlag/bitstring, 0:1,
	  PayloadLengthField/binary, Payload/binary>>;
format(Message=#mqtt_unsubscribe{topics=Topic}) ->
	format(Message#mqtt_unsubscribe{topics=[Topic]});
format(#mqtt_unsuback{message_id=MessageId, extra=Extra}) ->
	MessageIdField = format(MessageId),
	Payload = <<MessageIdField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<11:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_pingreq{extra=Extra}) ->
	PayloadLengthField = encode_number(size(Extra)),
	<<12:4/big-unsigned, 0:4, PayloadLengthField/binary, Extra/binary>>;
format(#mqtt_pingresp{extra=Extra}) ->
	PayloadLengthField = encode_number(size(Extra)),
	<<13:4/big-unsigned, 0:4, PayloadLengthField/binary, Extra/binary>>;
format(#mqtt_disconnect{extra=Extra}) ->
	PayloadLengthField = encode_number(size(Extra)),
	<<14:4/big-unsigned, 0:4, PayloadLengthField/binary, Extra/binary>>;
format(#mqtt_reserved{dup=Dup, qos=QoS, retain=Retain, extra=Extra}) ->
	DupFlag = format(Dup),
	QoSFlag = format(QoS),
	RetainFlag = format(Retain),
	PayloadLengthField = encode_number(size(Extra)),
	<<15:4/big-unsigned, DupFlag/bitstring, QoSFlag/bitstring, RetainFlag/bitstring,
	  PayloadLengthField/binary, Extra/binary>>.

encode_number(N) ->
	encode_number(N, <<>>).

encode_number(N, Acc) ->
	Rem = N rem 128,
	case N div 128 of
		0 ->
			<<Acc/binary, Rem:8/big-unsigned>>;
		Div ->
			encode_number(Div, <<Acc/binary, 1:1/unsigned, Rem:7/big-unsigned>>)
	end.

ssl_options() ->
	[verify, verify_fun, fail_if_no_peer_cert, depth, cert, certfile,
	 key, keyfile, password, cacerts, cacertfile, dh, dhfile, ciphers,
	 ssl_imp, reuse_sessions, reuse_session].

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_success_test_() ->
	[{"connect",
	  begin
		  Before1 = #?MODULE{buffer= <<1:4/big,0:4/big,18:8/big, % fixed header octet 1-2
									   6:16/big,"MQIsdp"/big, % protocol name octet 3-10
									   3:8/big, % protocol version octet 11
									   0:1,0:1,0:1,0:2,0:1,0:1,0:1, % connect flags octet 12
									   600:16/big, % keep alive timer octet 13-14
									   4:16/big,"test"/big>>}, % client id octet 15-20
		  Message1 = #mqtt_connect{keep_alive=600, client_id= <<"test">>},
		  After1 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message1, After1}, parse(Before1))
	  end},
	 {"connect+extra",
	  begin
		  Before2 = #?MODULE{buffer= <<1:4/big,0:4/big,28:8/big, % fixed header octet 1-2
									   6:16/big,"MQIsdp"/big, % protocol name octet 3-10
									   3:8/big, % protocol version octet 11
									   0:1,0:1,0:1,0:2,0:1,0:1,0:1, % connect flags octet 12
									   600:16/big, % keep alive timer octet 13-14
									   4:16/big,"test"/big, % client id octet 15-20
									   "extra data">>}, % extra octet 21-30
		  Message2 = #mqtt_connect{keep_alive=600, client_id= <<"test">>, extra= <<"extra data">>},
		  After2 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message2, After2}, parse(Before2))
	  end},
	 {"connect followed by more octets",
	  begin
		  Before3 = #?MODULE{buffer= <<1:4/big,0:4/big,18:8/big, % fixed header octet 1-2
									   6:16/big,"MQIsdp"/big, % protocol name octet 3-10
									   3:8/big, % protocol version octet 11
									   0:1,0:1,0:1,0:2,0:1,0:1,0:1, % connect flags octet 12
									   600:16/big, % keep alive timer octet 13-14
									   4:16/big,"test"/big, % client id octet 15-20
									   "more">>}, % octets to be parsed later
		  Message3 = #mqtt_connect{keep_alive=600, client_id= <<"test">>},
		  After3 = #?MODULE{buffer= <<"more">>},
		  ?_assertEqual({ok, Message3, After3}, parse(Before3))
	  end},
	 {"connack",
	  begin
		  Before4 = #?MODULE{buffer= <<2:4/big,0:4/big,2:8/big, % fixed header octet 1-2
									   0:16>>}, % return code octet 3-4
		  Message4 = #mqtt_connack{code=accepted},
		  After4 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message4, After4}, parse(Before4))
	  end},
	 {"connack+extra",
	  begin
		  Before5 = #?MODULE{buffer= <<2:4/big,0:4/big,12:8/big, % fixed header octet 1-2
									   0:16, % return code octet 3-4
									   "extra data">>}, % extra octet 5-14
		  Message5 = #mqtt_connack{code=accepted, extra= <<"extra data">>},
		  After5 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message5, After5}, parse(Before5))
	  end},
	 {"publish - qos 0",
	  begin
		  Before6 = #?MODULE{buffer= <<3:4/big,0:4/big,15:8/big, % fixed header octet 1-2
									   6:16/big,"to/pic", % topic octet 3-10
									   "payload">>}, % payload octet 11-17
		  Message6 = #mqtt_publish{topic= <<"to/pic">>, payload= <<"payload">>},
		  After6 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message6, After6}, parse(Before6))
	  end},
	 {"publish - qos 1",
	  begin
		  Before7 = #?MODULE{buffer= <<3:4/big,2:4/big,17:8/big, % fixed header octet 1-2
									   6:16/big,"to/pic", % topic octet 3-10
									   10:16/big, % message_id octet 11-12
									   "payload">>}, % payload octet 13-19
		  Message7 = #mqtt_publish{qos=at_least_once, message_id=10, topic= <<"to/pic">>, payload= <<"payload">>},
		  After7 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message7, After7}, parse(Before7))
	  end},
	 {"publish - qos 2",
	  begin
		  Before8 = #?MODULE{buffer= <<3:4/big,4:4/big,17:8/big, % fixed header octet 1-2
									   6:16/big,"to/pic", % topic octet 3-10
									   10:16/big, % message_id octet 11-12
									   "payload">>}, % payload octet 13-19
		  Message8 = #mqtt_publish{qos=exactly_once, message_id=10, topic= <<"to/pic">>, payload= <<"payload">>},
		  After8 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message8, After8}, parse(Before8))
	  end},
	 {"puback",
	  begin
		  Before9 = #?MODULE{buffer= <<4:4/big,0:4/big,2:8/big, % fixed header octet 1-2
									   10:16/big>>}, % message_id octet 3-4
		  Message9 = #mqtt_puback{message_id=10},
		  After9 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message9, After9}, parse(Before9))
	  end},
	 {"pubrec",
	  begin
		  Before10 = #?MODULE{buffer= <<5:4/big,0:4/big,2:8/big, % fixed header octet 1-2
										10:16/big>>}, % message_id octet 3-4
		  Message10 = #mqtt_pubrec{message_id=10},
		  After10 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message10, After10}, parse(Before10))
	  end},
	 {"pubrel",
	  begin
		  Before11 = #?MODULE{buffer= <<6:4/big,0:4/big,2:8/big, % fixed header octet 1-2
										10:16/big>>}, % message_id octet 3-4
		  Message11 = #mqtt_pubrel{message_id=10},
		  After11 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message11, After11}, parse(Before11))
	  end},
	 {"pubcomp",
	  begin
		  Before12 = #?MODULE{buffer= <<7:4/big,0:4/big,2:8/big, % fixed header octet 1-2
										10:16/big>>}, % message_id octet 3-4
		  Message12 = #mqtt_pubcomp{message_id=10},
		  After12 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message12, After12}, parse(Before12))
	  end},
	 {"subscribe",
	  begin
		  Before13 = #?MODULE{buffer= <<8:4/big,2:4/big,29:8/big, % fixed header octet 1-2
										10:16/big, % message_id octet 3-4
										6:16/big,"to/pic",0:8, % topic 1 octet 5-13
										6:16/big,"to/pid",1:8, % topic 2 octet 14-22
										6:16/big,"to/pie",2:8>>}, % topic 3 octet 23-31
		  Message13 = #mqtt_subscribe{message_id=10, topics=[{<<"to/pic">>, at_most_once},
															 {<<"to/pid">>, at_least_once},
															 {<<"to/pie">>, exactly_once}]},
		  After13 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message13, After13}, parse(Before13))
	  end},
	 {"suback",
	  begin
		  Before14 = #?MODULE{buffer= <<9:4/big,0:4/big,5:8/big, % fixed header octet 1-2
										10:16/big, % message_id octet 3-4
										0:8, % qos 1 octet 5
										1:8, % qos 2 octet 6
										2:8>>}, % qos 3 octet 7
		  Message14 = #mqtt_suback{message_id=10, qoss=[at_most_once,
														at_least_once,
														exactly_once]},
		  After14 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message14, After14}, parse(Before14))
	  end},
	 {"unsubscribe",
	  begin
		  Before15 = #?MODULE{buffer= <<10:4/big,2:4/big,26:8/big, % fixed header octet 1-2
										10:16/big, % message_id octet 3-4
										6:16/big,"to/pic", % topic 1 octet 5-12
										6:16/big,"to/pid", % topic 2 octet 13-20
										6:16/big,"to/pie">>}, % topic 3 octet 21-28
		  Message15 = #mqtt_unsubscribe{message_id=10, topics=[<<"to/pic">>,
															   <<"to/pid">>,
															   <<"to/pie">>]},
		  After15 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message15, After15}, parse(Before15))
	  end},
	 {"unsuback",
	  begin
		  Before16 = #?MODULE{buffer= <<11:4/big,0:4/big,2:8/big, % fixed header octet 1-2
										10:16/big>>}, % message_id octet 3-4
		  Message16 = #mqtt_unsuback{message_id=10},
		  After16 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message16, After16}, parse(Before16))
	  end},
	 {"pingreq",
	  begin
		  Before17 = #?MODULE{buffer= <<12:4/big,0:4/big,0:8/big>>}, % fixed header octet 1-2
		  Message17 = #mqtt_pingreq{},
		  After17 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message17, After17}, parse(Before17))
	  end},
	 {"pingresp",
	  begin
		  Before18 = #?MODULE{buffer= <<13:4/big,0:4/big,0:8/big>>}, % fixed header octet 1-2
		  Message18 = #mqtt_pingresp{},
		  After18 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message18, After18}, parse(Before18))
	  end},
	 {"disconnect",
	  begin
		  Before19 = #?MODULE{buffer= <<14:4/big,0:4/big,0:8/big>>}, % fixed header octet 1-2
		  Message19 = #mqtt_disconnect{},
		  After19 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message19, After19}, parse(Before19))
	  end},
	 {"connect with alt server extension",
	  begin
		  Before20 = #?MODULE{buffer= <<1:4/big,0:4/big,20:8/big, % fixed header octet 1-2
									    6:16/big,"MQIsdp"/big, % protocol name octet 3-10
									    3:8/big, % protocol version octet 11
									    0:1,0:1,0:1,0:2,0:1,0:1,1:1, % connect flags octet 12
									    600:16/big, % keep alive timer octet 13-14
									    4:16/big,"test"/big, % client id octet 15-20
									    10:16/big, % max_recursion field
									    "more">>}, % octets to be parsed later
		  Message20 = #mqtt_connect{keep_alive=600, client_id= <<"test">>, max_recursion=10},
		  After20 = #?MODULE{buffer= <<"more">>},
		  ?_assertEqual({ok, Message20, After20}, parse(Before20))
	  end},
	 {"connack with alt server extension",
	  begin
		  Before21 = #?MODULE{buffer= <<2:4/big,0:4/big,22:8/big, % fixed header octet 1-2
										6:16/big, % return code octet 3-4
										16:16/big, "tcp:1.2.3.4:1883"/big, % alt server octet 5-22
										3:16/big>>}, % max recursion octet 23-24
		  Message21 = #mqtt_connack{code=alt_server, alt_server= <<"tcp:1.2.3.4:1883">>, max_recursion=3},
		  After21 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({ok, Message21, After21}, parse(Before21))
	  end}].

parse_failure_test_() ->
	[{"zero byte",
	  begin
		  Before0 = #?MODULE{buffer= <<>>},
		  ?_assertEqual({more, Before0}, parse(Before0))
	  end},
	 {"one byte",
	  begin
		  Before1 = #?MODULE{buffer= <<0:4/big,0:4/big>>}, % fixed header only
		  ?_assertMatch({more, #?MODULE{buffer= <<>>, header=#mqtt_header{size=undefined}}}, parse(Before1))
	  end},
	 {"two bytes",
	  begin
		  Before2 = #?MODULE{buffer= <<0:4/big,0:4/big,10:8/big>>}, % fixed header + length
		  ?_assertMatch({more, #?MODULE{buffer= <<>>, header=#mqtt_header{size=10}}}, parse(Before2))
	  end},
	 {"four bytes",
	  begin
		  Before3 = #?MODULE{buffer= <<0:4/big,0:4/big,10:8/big, % fixed header + length
									   "mo">>}, % incomplete packet
		  ?_assertMatch({more, #?MODULE{buffer= <<"mo">>, header=#mqtt_header{size=10}}}, parse(Before3))
	  end},
	 {"overflow",
	  begin
		  Default = #?MODULE{},
		  N = encode_number(Default#?MODULE.max_packet_size+1),
		  Before4 = #?MODULE{buffer= <<0:4/big,0:4/big,N/binary>>}, % fixed header + length
		  ?_assertMatch({error, overflow, _}, parse(Before4))
	  end}].

format_test_() ->
	[{"connect",
	  begin
		  ?_assertEqual(<<1:4,0:4,45:8,
						  6:16/big,"MQIsdp",3:8, % 1-9
						  1:1,1:1,0:1,0:2,1:1,0:1,0:1, % 10
						  600:16/big, % 11-12
						  4:16/big,"test", % 13-18
						  4:16/big,"will", % 19-24
						  6:16/big,"byebye", % 25-32
						  5:16/big,"romeo", % 33-39
						  4:16/big,"1234">>, % 40-45
						  format(#mqtt_connect{username= <<"romeo">>,
								 			   password= <<"1234">>,
											   will_topic= <<"will">>,
											   will_message= <<"byebye">>,
											   keep_alive=600,
											   client_id= <<"test">>}))
	  end},
	 {"connect with alt server extension",
	  begin
		  ?_assertEqual(<<1:4,0:4,47:8,
						  6:16/big,"MQIsdp",3:8, % 1-9
						  1:1,1:1,0:1,0:2,1:1,0:1,1:1, % 10
						  600:16/big, % 11-12
						  4:16/big,"test", % 13-18
						  4:16/big,"will", % 19-24
						  6:16/big,"byebye", % 25-32
						  5:16/big,"romeo", % 33-39
						  4:16/big,"1234", % 40-45
						  10:16/big>>, % 46-47
						  format(#mqtt_connect{username= <<"romeo">>,
								 			   password= <<"1234">>,
											   will_topic= <<"will">>,
											   will_message= <<"byebye">>,
											   keep_alive=600,
											   client_id= <<"test">>,
											   max_recursion=10}))
	  end},
	 {"connack",
	  begin
		  ?_assertEqual(<<2:4,0:4,7:8,
						  0:16/big, % 1-2
						  "hello">>, % 3-7
						  format(#mqtt_connack{code=accepted, extra= <<"hello">>}))
	  end},
	 {"connack with alt server extension",
	  begin
		  ?_assertEqual(<<2:4,0:4,27:8,
						  0:8/big, 6:8/big, % 1-2
						  16:16/big, "tcp:1.2.3.4:1883"/big, % 3-20
						  3:16/big, % 21-22
						  "hello">>, % 23-27
						  format(#mqtt_connack{code=alt_server, alt_server= <<"tcp:1.2.3.4:1883">>, max_recursion=3, extra= <<"hello">>}))
	  end},
	 {"publish - qos 0",
	  begin
		  ?_assertEqual(<<3:4,0:4,15:8,
						  6:16/big,"to/pic", % 1-8
						  "payload">>, % 9-15
						  format(#mqtt_publish{topic= <<"to/pic">>,
											   payload= <<"payload">>}))
	  end},
	 {"publish - qos 1",
	  begin
		  ?_assertEqual(<<3:4,2:4,17:8,
						  6:16/big,"to/pic", % 1-8
						  10:16/big, % 9-10
						  "payload">>, % 11-17
						  format(#mqtt_publish{topic= <<"to/pic">>,
											   message_id=10,
											   qos=at_least_once,
											   payload= <<"payload">>}))
	  end},
	 {"publish - qos 2",
	  begin
		  ?_assertEqual(<<3:4,4:4,17:8,
						  6:16/big,"to/pic", % 1-8
						  10:16/big, % 9-10
						  "payload">>, % 11-17
						  format(#mqtt_publish{topic= <<"to/pic">>,
											   message_id=10,
											   qos=exactly_once,
											   payload= <<"payload">>}))
	  end},
	{"puback",
	  begin
		  ?_assertEqual(<<4:4,0:4,2:8,
						  10:16/big>>, % 1-2
						  format(#mqtt_puback{message_id=10}))
	  end},
	 {"pubrec",
	  begin
		  ?_assertEqual(<<5:4,0:4,2:8,
						  10:16/big>>, % 1-2
						  format(#mqtt_pubrec{message_id=10}))
	  end},
	 {"pubrel",
	  begin
		  ?_assertEqual(<<6:4,0:4,2:8,
						  10:16/big>>, % 1-2
						  format(#mqtt_pubrel{message_id=10}))
	  end},
	 {"pubcomp",
	  begin
		  ?_assertEqual(<<7:4,0:4,2:8,
						  10:16/big>>, % 1-2
						  format(#mqtt_pubcomp{message_id=10}))
	  end},
	 {"subscribe",
	  begin
		  ?_assertEqual(<<8:4,2:4,29:8,
						  10:16/big, % 1-2
						  6:16/big,"to/pic",0:8, % 3-11
						  6:16/big,"to/pid",1:8, % 12-20 
						  6:16/big,"to/pie",2:8>>, % 21-29
						  format(#mqtt_subscribe{message_id=10,
												 topics=[{<<"to/pic">>, at_most_once},
														 {<<"to/pid">>, at_least_once},
														 {<<"to/pie">>, exactly_once}]}))
	  end},
	 {"suback",
	  begin
		  ?_assertEqual(<<9:4,0:4,5:8,
						  10:16/big, % 1-2
						  0:8, % 3
						  1:8, % 4
						  2:8>>, % 5
						  format(#mqtt_suback{message_id=10,
											  qoss=[at_most_once,
													at_least_once,
													exactly_once]}))
	  end},
	 {"unsubscribe",
	  begin
		  ?_assertEqual(<<10:4,2:4,26:8,
						  10:16/big, % 1-2
						  6:16/big,"to/pic", % 3-10
						  6:16/big,"to/pid", % 11-18 
						  6:16/big,"to/pie">>, % 19-26
						format(#mqtt_unsubscribe{message_id=10,
												 topics=[<<"to/pic">>,
														 <<"to/pid">>,
														 <<"to/pie">>]}))
	  end},
	 {"unsuback",
	  begin
		  ?_assertEqual(<<11:4,0:4,2:8,
						  10:16/big>>, % 1-2
						  format(#mqtt_unsuback{message_id=10}))
	  end},
	 {"pingreq",
	  begin
		  ?_assertEqual(<<12:4,0:4,0:8>>,
						  format(#mqtt_pingreq{}))
	  end},
	 {"pingresp",
	  begin
		  ?_assertEqual(<<13:4,0:4,0:8>>,
						  format(#mqtt_pingresp{}))
	  end},
	 {"disconnect",
	  begin
		  ?_assertEqual(<<14:4,0:4,0:8>>,
						  format(#mqtt_disconnect{}))
	  end}].

-endif.
