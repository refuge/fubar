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
			Data = format(Reply),
			lager:debug("STREAM OUT ~p", [Data]),
			{reply, {binary, Data}, Req, State#?MODULE{context=NewContext, timeout=Timeout}};
		{reply_later, Reply, NewContext, Timeout} ->
			self() ! {send, Reply},
			{ok, Req, State#?MODULE{context=NewContext, timeout=Timeout}};
		{noreply, NewContext, Timeout} ->
			Req2 = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, <<"mqttv3.1">>, Req),
			{ok, Req2, State#?MODULE{context=NewContext, timeout=Timeout}};
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
	case parse(State#?MODULE{buffer= <<Buffer/binary, Data/binary>>}) of
		{ok, Message, NewState} ->
			% Parsed one message.
			% Call dispatcher.
			case Dispatch:handle_message(Message, Context) of
				{reply, Reply, NewContext, NewTimeout} ->
					Data1 = format(Reply),
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
	Data = format(Reply),
	lager:debug("STREAM OUT: ~p", [Data]),
	{reply, {binary, Data}, Req, State};
websocket_info(Info, Req, State=#?MODULE{dispatch=Dispatch, context=Context}) ->
	case Dispatch:handle_event(Info, Context) of
		{reply, Reply, NewContext, NewTimeout} ->
			Data = format(Reply),
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
	Dispatch:terminate(Reason, Context),
	ok.

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
