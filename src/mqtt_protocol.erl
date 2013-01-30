%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT protocol parser.
%%%     This is initially designed to run under ranch framework but
%%% later extended to run independently.  This module represens a
%%% process that receives tcp bytestream, parses it to produce mqtt
%%% packets and calls a dispatcher, which is given as a parameter
%%% {dispatch, Module} when starting the process.  The dispatcher
%%% must have at least 4 functions init/1, handle_message/2,
%%% handle_event/2 and terminate/1 defined.  Refer mqtt_server for
%%% example.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt_protocol).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("mqtt.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").
 
%%
%% Records
%%
-record(?MODULE, {host = "localhost" :: hostname() | ipaddr(), % for client mode
				  port = 1883 :: ipport(), % for client mode
				  listener :: pid(), % for server mode
				  transport = ranch_tcp :: module(),
				  socket :: port(),
				  socket_options = [] :: proplist(atom(), term()),
				  acl_socket_options = [] :: proplist(atom(), term()),
				  max_packet_size = 4096 :: pos_integer(),
				  acl = undefined :: module(),
				  header,
				  buffer = <<>> :: binary(),
				  dispatch :: module(),
				  context = [] :: any(),
				  timeout :: timeout()}).

%%
%% Exports
%%
-export([start/1, start_link/4, stop/1, setopts/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Start an MQTT client process.
%%      Settings should be given as a parameter -- the application metadata doesn't apply.
-spec start(proplist(atom(), term())) -> {ok, pid()} | {error, reason()}.
start(Props) ->
	State = ?PROPS_TO_RECORD(Props, ?MODULE),
	gen_server:start(?MODULE, State#?MODULE{context=Props}, []).

%% @doc Start an MQTT server process that receives and parses packets.
%%      This function is called when the listener(ranch) accepts a connection.
-spec start_link(pid(), port(), module(), proplist(atom(), term())) ->
		  {ok, pid()} | {error, reason()}.
start_link(Listener, Socket, Transport, Options) ->
	% Apply settings from the application metadata.
	case fubar_alarm:is_alarmed() of
		true ->
			Transport:close(Socket),
			Stop = {error, overload},
			fubar_log:error(?MODULE, Stop),
			Stop;
		_ ->
			Settings = fubar:settings(?MODULE),
			State = ?PROPS_TO_RECORD(Settings ++ Options, ?MODULE),
			gen_server:start_link(?MODULE, State#?MODULE{listener=Listener, socket=Socket, transport=Transport}, [])
	end.

%% @doc Stop the process.
-spec stop(pid()) -> ok | {error, reason()}.
stop(Pid) ->
	gen_server:cast(Pid, stop).

%% @doc Set socket options.
-spec setopts(pid(), proplist(atom(), term())) -> ok.
setopts(Pid, Options) ->
	gen_server:cast(Pid, {setopts, Options}).

%%
%% Callback functions
%%

%% Initialize the protocol in client mode.
init(State=#?MODULE{host=Host, port=Port, transport=Transport,
					socket=undefined, socket_options=Options}) ->
	case catch Transport:connect(Host, Port, Options) of
		{ok, Socket} ->
			{ok, {SockAddr, SockPort}} = Transport:sockname(Socket),
			fubar_log:access(?MODULE, ["connection from", SockAddr, SockPort]),
			NewOptions = lists:foldl(fun(Key, Acc) ->
											 proplists:delete(Key, Acc)
									 end, Options, ssl_options()),
			NewState = State#?MODULE{socket=Socket, socket_options=NewOptions},
			case Socket of
				{sslsocket, _, _} ->
					fubar_log:debug(?MODULE, ssl:connection_info(Socket)),
					case ssl:peercert(Socket) of
						{ok, _} ->
							client_init(NewState);
						Error ->
							{stop, Error}
					end;
				_ ->
					client_init(NewState)
			end;
		Error1 ->
			{stop, Error1}
	end;

%% Initialize the protocol in server mode.
init(State=#?MODULE{transport=Transport, socket=Socket}) ->
	% Leave access log.
	{ok, {PeerAddr, PeerPort}} = Transport:peername(Socket),
	fubar_log:access(?MODULE, ["connection from", PeerAddr, PeerPort]),
	case State#?MODULE.acl of
		undefined ->
			server_init(State);
		Module ->
			case Module:verify(PeerAddr) of
				ok ->
					fubar_log:debug(?MODULE, ["acl pass", PeerAddr]),
					server_init(State#?MODULE{socket_options=State#?MODULE.acl_socket_options,
											  context=[{auth, undefined}]});
				{error, not_found} ->
					server_init(State);
				{error, forbidden} ->
					fubar_log:warning(?MODULE, ["acl block", PeerAddr]),
					Transport:close(Socket),
					{ok, State#?MODULE{socket=undefined, timeout=0}, 0}
			end
	end.

client_init(State=#?MODULE{transport=Transport, socket=Socket, socket_options=Options,
						   dispatch=Dispatch, context=Context}) ->
	case Dispatch:init(Context) of
		{reply, Reply, NewContext, Timeout} ->
			Transport:send(Socket, format(Reply)),
			Transport:setopts(Socket, Options ++ [{active, once}]),
			{ok, State#?MODULE{context=NewContext, timeout=Timeout}, Timeout};
		{reply_later, Reply, NewContext, Timeout} ->
			gen_server:cast(self(), {send, Reply}),
			Transport:setopts(Socket, Options ++ [{active, once}]),
			{ok, State#?MODULE{context=NewContext, timeout=Timeout}, Timeout};
		{noreply, NewContext, Timeout} ->
			Transport:setopts(Socket, Options ++ [{active, once}]),
			{ok, State#?MODULE{context=NewContext, timeout=Timeout}, Timeout};
		{stop, Reason} ->
			{stop, Reason}
	end.

server_init(State=#?MODULE{transport=Transport, socket=Socket, socket_options=Options}) ->
	case Socket of
		{sslsocket, _, _} ->
			fubar_log:debug(?MODULE, [ssl, ssl:connection_info(Socket)]),
			NewOptions = lists:foldl(fun(Key, Acc) ->
											 proplists:delete(Key, Acc)
									 end, Options, ssl_options()),
			NewState = State#?MODULE{socket_options=NewOptions},
			case ssl:peercert(Socket) of
				{ok, _} ->
					server_init(NewState, ok);
				Error ->
					case proplists:get_value(verify, Options) of
						verify_peer ->
							% The client is not certified and rejected.
							fubar_log:warning(?MODULE, ["ssl cert not ok", Error]),
							Transport:close(Socket),
							{ok, NewState#?MODULE{socket=undefined, timeout=0}, 0};
						_ ->
							% The client is not certified but accepted.
							server_init(NewState, ok)
					end
			end;
		_ ->
			server_init(State, ok)
	end.

server_init(State=#?MODULE{transport=Transport, socket=Socket, socket_options=Options,
						   dispatch=Dispatch, context=Context}, ok) ->
	case Dispatch:init(Context) of
		{reply, Reply, NewContext, Timeout} ->
			Data = format(Reply),
			fubar_log:packet(?MODULE, ["sending", Data]),
			case catch Transport:send(Socket, Data) of
				ok ->
					Transport:setopts(Socket, Options ++ [{active, once}]),
					{ok, State#?MODULE{context=NewContext, timeout=Timeout}, Timeout};
				{error, Reason} ->
					fubar_log:warning(?MODULE, ["socket failure", Reason]),
					{stop, normal};
				Exit ->
					fubar_log:warning(?MODULE, ["socket failure", Exit]),
					{stop, normal}
			end;
		{reply_later, Reply, NewContext, Timeout} ->
			gen_server:cast(self(), {send, Reply}),
			Transport:setopts(Socket, Options ++ [{active, once}]),
			{ok, State#?MODULE{context=NewContext, timeout=Timeout}, Timeout};
		{noreply, NewContext, Timeout} ->
			Transport:setopts(Socket, Options ++ [{active, once}]),
			{ok, State#?MODULE{context=NewContext, timeout=Timeout}, Timeout};
		{stop, Reason} ->
			fubar_log:debug(?MODULE, ["dispatch init failure", Reason]),
			{stop, normal}
	end.

%% Fallback
handle_call(Request, From, State=#?MODULE{timeout=Timeout}) ->
	fubar_log:debug(?MODULE, ["unknown call", Request, From]),
	{reply, {error, unknown}, State, Timeout}.

%% Async administrative commands.
handle_cast({send, Message}, State=#?MODULE{transport=Transport, socket=Socket,
											dispatch=Dispatch, context=Context,
											timeout=Timeout}) ->
	Data = format(Message),
	fubar_log:log(packet, ?MODULE, ["sending", Data]),
	case catch Transport:send(Socket, Data) of
		ok ->
			{noreply, State, Timeout};
		{error, Reason} ->
			fubar_log:warning(?MODULE, ["socket failure", Reason]),
			{stop, Dispatch:terminate(Context), State#?MODULE{socket=undefined}};
		Exit ->
			fubar_log:warning(?MODULE, ["socket failure", Exit]),
			{stop, Dispatch:terminate(Context), State#?MODULE{socket=undefined}}
	end;
handle_cast(stop, State) ->
	{stop, normal, State};

%% Fallback
handle_cast(Message, State=#?MODULE{timeout=Timeout}) ->
	fubar_log:log(debug, ?MODULE, ["unknown cast", Message]),
	{noreply, State, Timeout}.

% Ignore pointless message from the listener.
handle_info({shoot, Listener}, State=#?MODULE{listener=Listener, timeout=Timeout}) ->
	{noreply, State, Timeout};

%% Apply socket options.
handle_info({setopts, Options}, State=#?MODULE{transport=Transport, socket=Socket, timeout=Timeout}) ->
	fubar_log:log(debug, ?MODULE, ["setopts", Options]),
	Transport:setopts(Socket, Options ++ [{active, once}]),
	{noreply, State, Timeout};

%% Received tcp data, start parsing.
handle_info({tcp, Socket, Data}, State=#?MODULE{transport=Transport, socket=Socket, buffer=Buffer,
												dispatch=Dispatch, context=Context, timeout=Timeout}) ->
	case Data of
		<<>> -> ok;
		_ -> fubar_log:packet(?MODULE, ["received", Data])
	end,
	% Append the packet at the end of the buffer and start parsing.
	case parse(State#?MODULE{buffer= <<Buffer/binary, Data/binary>>}) of
		{ok, Message, NewState} ->
			% Parsed one message.
			% Call dispatcher.
			case Dispatch:handle_message(Message, Context) of
				{reply, Reply, NewContext, NewTimeout} ->
					Data1 = format(Reply),
					fubar_log:packet(?MODULE, ["sending", Data1]),
					case catch Transport:send(Socket, Data1) of
						ok ->
							% Simulate new tcp data to trigger next parsing schedule.
							self() ! {tcp, Socket, <<>>},
							{noreply, NewState#?MODULE{context=NewContext, timeout=NewTimeout}, NewTimeout};
						{error, Reason} ->
							fubar_log:warning(?MODULE, ["socket failure", Reason]),
							{stop, Dispatch:terminate(NewContext), State#?MODULE{socket=undefined}};
						Exit ->
							fubar_log:warning(?MODULE, ["socket failure", Exit]),
							{stop, Dispatch:terminate(NewContext), State#?MODULE{socket=undefined}}
					end;
				{reply_later, Reply, NewContext, NewTimeout} ->
					gen_server:cast(self(), {send, Reply}),
					self() ! {tcp, Socket, <<>>},
					{noreply, NewState#?MODULE{context=NewContext, timeout=NewTimeout}, NewTimeout};
				{noreply, NewContext, NewTimeout} ->
					self() ! {tcp, Socket, <<>>},
					{noreply, NewState#?MODULE{context=NewContext, timeout=NewTimeout}, NewTimeout};
				{stop, Reason, NewContext} ->
					fubar_log:debug(?MODULE, ["dispatch issued stop", Reason]),
					{stop, Dispatch:terminate(NewContext), NewState#?MODULE{context=NewContext}}
			end;
		{more, NewState} ->
			% The socket gets active after consuming previous data.
			Transport:setopts(Socket, [{active, once}]),
			{noreply, NewState, Timeout};
		{error, Reason, NewState} ->
			fubar_log:warning(?MODULE, ["parse error", Reason]),
			{stop, Dispatch:terminate(Context), NewState}
	end;
handle_info({ssl, Socket, Data}, State) ->
	handle_info({tcp, Socket, Data}, State);

%% Socket close detected.
handle_info({tcp_closed, Socket}, State=#?MODULE{socket=Socket, dispatch=Dispatch, context=Context}) ->
	{stop, Dispatch:terminate(Context), State#?MODULE{socket=undefined}};
handle_info({ssl_closed, Socket}, State=#?MODULE{socket=Socket, dispatch=Dispatch, context=Context}) ->
	{stop, Dispatch:terminate(Context), State#?MODULE{socket=undefined}};

%% Invoke dispatcher to handle all the other events.
handle_info(Info, State=#?MODULE{transport=Transport, socket=Socket,
								 dispatch=Dispatch, context=Context}) ->
	case Dispatch:handle_event(Info, Context) of
		{reply, Reply, NewContext, NewTimeout} ->
			Data = format(Reply),
			fubar_log:packet(?MODULE, ["sending", Data]),
			case catch Transport:send(Socket, Data) of
				ok ->
					{noreply, State#?MODULE{context=NewContext, timeout=NewTimeout}, NewTimeout};
				{error, Reason} ->
					fubar_log:warning(?MODULE, ["socket failure", Reason]),
					{stop, normal, State#?MODULE{socket=undefined}};
				Exit ->
					fubar_log:warning(?MODULE, ["socket failure", Exit]),
					{stop, Dispatch:terminate(NewContext), State#?MODULE{socket=undefined}}
			end;
		{reply_later, Reply, NewContext, NewTimeout} ->
			gen_server:cast(self(), {send, Reply}),
			{noreply, State#?MODULE{context=NewContext, timeout=NewTimeout}, NewTimeout};
		{noreply, NewContext, NewTimeout} ->
			{noreply, State#?MODULE{context=NewContext, timeout=NewTimeout}, NewTimeout};
		{stop, Reason, NewContext} ->
			fubar_log:debug(?MODULE, ["dispatch issued stop", Reason]),
			{stop, Dispatch:terminate(NewContext), State#?MODULE{context=NewContext}}
	end.

%% Termination logic.
terminate(Reason, #?MODULE{transport=Transport, socket=Socket}) ->
	case Socket of
		undefined ->
			fubar_log:log(access, ?MODULE, ["socket closed", Reason]);
		_ ->
			fubar_log:log(access, ?MODULE, ["closing socket", Reason]),
			Transport:close(Socket)
	end.

code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local functions
%%
parse(State=#?MODULE{header=undefined, buffer= <<>>}) ->
	% Not enough data to start parsing.
	{more, State};
parse(State=#?MODULE{header=undefined, buffer=Buffer}) ->
	% Read fixed header part and go on.
	{Fixed, Rest} = read_fixed_header(Buffer),
	parse(State#?MODULE{header=Fixed, buffer=Rest});
parse(State=#?MODULE{header=Header, buffer=Buffer, max_packet_size=MaxPacketSize})
  when Header#mqtt_header.size =:= undefined ->
	% Read size part.
	case decode_number(Buffer) of
		{ok, N, Payload} ->
			NewHeader = Header#mqtt_header{size=N},
			case N of
				_ when MaxPacketSize < N+2 ->
					{error, overflow, State#?MODULE{header=NewHeader}};
				_ ->
					parse(State#?MODULE{header=NewHeader, buffer=Payload})
			end;
		more when MaxPacketSize < size(Buffer)+1 ->
			{error, overflow, State};
		more ->
			{more, State};
		{error, Reason} ->
			{error, Reason, State}
	end;
parse(State=#?MODULE{header=Header, buffer=Buffer})
  when size(Buffer) >= Header#mqtt_header.size ->
	% Ready to read payload.
	case catch read_payload(Header, Buffer) of
		{ok, Message, Rest} ->
			% Copy the buffer to prevent the binary from increasing indefinitely.
			{ok, Message, State#?MODULE{header=undefined, buffer=Rest}};
		{'EXIT', From, Reason} ->
			{error, {'EXIT', From, Reason}}
	end;
parse(State) ->
	{more, State}.

decode_number(Binary) ->
	split_number(Binary, <<>>).

split_number(<<>>, _) ->
	more;
split_number(<<1:1/unsigned, N:7/bitstring, Rest/binary>>, Buffer) ->
	split_number(Rest, <<Buffer/binary, 0:1, N/bitstring>>);
split_number(<<N:8/bitstring, Rest/binary>>, Buffer) ->
	{ok, read_number(<<Buffer/binary, N/bitstring>>), Rest}.

read_number(<<>>) ->
	0;
read_number(<<N:8/big, T/binary>>) ->
	N + 128*read_number(T).

read_fixed_header(Buffer) ->
	<<Type:4/big-unsigned, Dup:1/unsigned,
	  QoS:2/big-unsigned, Retain:1/unsigned,
	  Rest/binary>> = Buffer,
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

read_payload(Header=#mqtt_header{type=Type, size=Size}, Buffer) ->
	% Need to split a payload first.
	<<Payload:Size/binary, Rest/binary>> = Buffer,
	Message = case Type of
				  mqtt_reserved ->
					  read_reserved(Header, binary:copy(Payload));
				  mqtt_connect ->
					  read_connect(Header, binary:copy(Payload));
				  mqtt_connack ->
					  read_connack(Header, binary:copy(Payload));
				  mqtt_publish ->
					  read_publish(Header, binary:copy(Payload));
				  mqtt_puback ->
					  read_puback(Header, binary:copy(Payload));
				  mqtt_pubrec ->
					  read_pubrec(Header, binary:copy(Payload));
				  mqtt_pubrel ->
					  read_pubrel(Header, binary:copy(Payload));
				  mqtt_pubcomp ->
					  read_pubcomp(Header, binary:copy(Payload));
				  mqtt_subscribe ->
					  read_subscribe(Header, binary:copy(Payload));
				  mqtt_suback ->
					  read_suback(Header, binary:copy(Payload));
				  mqtt_unsubscribe ->
					  read_unsubscribe(Header, binary:copy(Payload));
				  mqtt_unsuback ->
					  read_unsuback(Header, binary:copy(Payload));
				  mqtt_pingreq ->
					  read_pingreq(Header, binary:copy(Payload));
				  mqtt_pingresp ->
					  read_pingresp(Header, binary:copy(Payload));
				  mqtt_disconnect ->
					  read_disconnect(Header, binary:copy(Payload));
				  _ ->
					  undefined
			  end,
	{ok, Message, binary:copy(Rest)}.

read_connect(_Header,
			 <<ProtocolLength:16/big-unsigned, Protocol:ProtocolLength/binary,
			   Version:8/big-unsigned, UsernameFlag:1/unsigned, PasswordFlag:1/unsigned,
			   WillRetain:1/unsigned, WillQoS:2/big-unsigned, WillFlag:1/unsigned,
			   CleanSession:1/unsigned, _Reserved:1/unsigned, KeepAlive:16/big-unsigned,
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
								{undefined, Rest1};
							_ ->
								<<UsernameLength:16/big-unsigned, Username_:UsernameLength/binary, Rest2_/binary>> = Rest1,
								{Username_, Rest2_}
						end,
	{Password, Rest3} = case PasswordFlag of
							 0 ->
								 {undefined, Rest2};
							 _ ->
								 <<PasswordLength:16/big-unsigned, Password_:PasswordLength/binary, Rest3_/binary>> = Rest2,
								 {Password_, Rest3_}
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
				  extra=Rest3}.
	
read_connack(_Header,
			 <<_Reserved:8/big-unsigned, Code:8/big-unsigned, Rest/binary>>) ->
	#mqtt_connack{code=case Code of
						   0 -> accepted;
						   1 -> incompatible;
						   2 -> id_rejected;
						   3 -> unavailable;
						   4 -> forbidden;
						   5 -> unauthorized;
						   _ -> undefined
					   end,
				  extra=Rest}.

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
					 extra=Extra}) ->
	ProtocolField = format(Protocol),
	{UsernameFlag, UsernameField} = case Username of
										undefined ->
											{<<0:1>>, <<>>};
										_ ->
											{<<1:1/unsigned>>, format(Username)}
									end,
	{PasswordFlag, PasswordField} = case Password of
										undefined ->
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
	KeepAliveValue = case KeepAlive of
						 infinity -> 0;
						 _ -> KeepAlive
					 end,
	ClientIdField = format(ClientId),
	Payload = <<ProtocolField/binary, Version:8/big-unsigned, UsernameFlag/bitstring,
				PasswordFlag/bitstring, WillRetainFlag/bitstring, WillQoSFlag/bitstring,
				WillFlag/bitstring, CleanSessionFlag/bitstring, 0:1, KeepAliveValue:16/big-unsigned,
				ClientIdField/binary, WillTopicField/binary, WillMessageField/binary,
				UsernameField/binary, PasswordField/binary, Extra/binary>>,
	PayloadLengthField = encode_number(size(Payload)),
	<<1:4/big-unsigned, 0:4, PayloadLengthField/binary, Payload/binary>>;
format(#mqtt_connack{code=Code, extra=Extra}) ->
	CodeField = case Code of
					accepted -> <<0:8/big-unsigned>>;
					incompatible -> <<1:8/big-unsigned>>;
					id_rejected -> <<2:8/big-unsigned>>;
					unavailable -> <<3:8/big-unsigned>>;
					forbidden -> <<4:8/big-unsigned>>;
					unauthorized -> <<5:8/big-unsigned>>;
					_ -> <<6:8/big-unsigned>>
				end,
	Payload = <<0:8, CodeField/bitstring, Extra/binary>>,
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
-endif.
