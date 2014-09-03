%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT message handling utility.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Includes
%%
-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

%%
%% Exports
%%
-export([connect/1, connack/1, publish/1, puback/1, pubrec/1, pubrel/1, pubcomp/1,
		 subscribe/1, suback/1, unsubscribe/1, unsuback/1, pingreq/1, pingresp/1, disconnect/1,
		 message_id/1, set_dup/1, is_same/2, degrade/2]).

-spec connect(proplist(atom(), term())) -> #mqtt_connect{}.
connect(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_connect).

-spec connack(proplist(atom(), term())) -> #mqtt_connack{}.
connack(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_connack).

-spec publish(proplist(atom(), term())) -> #mqtt_publish{}.
publish(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_publish).

-spec puback(proplist(atom(), term())) -> #mqtt_puback{}.
puback(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_puback).

-spec pubrec(proplist(atom(), term())) -> #mqtt_pubrec{}.
pubrec(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_pubrec).

-spec pubrel(proplist(atom(), term())) -> #mqtt_pubrel{}.
pubrel(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_pubrel).

-spec pubcomp(proplist(atom(), term())) -> #mqtt_pubcomp{}.
pubcomp(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_pubcomp).

-spec subscribe(proplist(atom(), term())) -> #mqtt_subscribe{}.
subscribe(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_subscribe).

-spec suback(proplist(atom(), term())) -> #mqtt_suback{}.
suback(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_suback).

-spec unsubscribe(proplist(atom(), term())) -> #mqtt_unsubscribe{}.
unsubscribe(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_unsubscribe).

-spec unsuback(proplist(atom(), term())) -> #mqtt_unsuback{}.
unsuback(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_unsuback).

-spec pingreq(proplist(atom(), term())) -> #mqtt_pingreq{}.
pingreq(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_pingreq).

-spec pingresp(proplist(atom(), term())) -> #mqtt_pingresp{}.
pingresp(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_pingresp).

-spec disconnect(proplist(atom(), term())) -> #mqtt_disconnect{}.
disconnect(Props) ->
	?PROPS_TO_RECORD(Props, mqtt_disconnect).

-spec message_id(mqtt_message()) -> non_neg_integer().
message_id(#mqtt_publish{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_puback{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_pubrec{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_pubrel{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_pubcomp{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_subscribe{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_suback{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_unsubscribe{message_id=MessageId}) ->
	MessageId;
message_id(#mqtt_unsuback{message_id=MessageId}) ->
	MessageId;
message_id(_) ->
	0.

-spec set_dup(mqtt_message()) -> mqtt_message().
set_dup(Message=#mqtt_publish{}) ->
	Message#mqtt_publish{dup=true};
set_dup(Message=#mqtt_subscribe{}) ->
	Message#mqtt_subscribe{dup=true};
set_dup(Message=#mqtt_unsubscribe{}) ->
	Message#mqtt_unsubscribe{dup=true};
set_dup(Message) ->
	Message.

-spec is_same(mqtt_message(), mqtt_message()) -> boolean().
is_same(#mqtt_publish{message_id=MessageId}, #mqtt_publish{message_id=MessageId}) ->
	true;
is_same(#mqtt_puback{message_id=MessageId}, #mqtt_puback{message_id=MessageId}) ->
	true;
is_same(#mqtt_pubrec{message_id=MessageId}, #mqtt_pubrec{message_id=MessageId}) ->
	true;
is_same(#mqtt_pubrel{message_id=MessageId}, #mqtt_pubrel{message_id=MessageId}) ->
	true;
is_same(#mqtt_pubcomp{message_id=MessageId}, #mqtt_pubcomp{message_id=MessageId}) ->
	true;
is_same(#mqtt_subscribe{message_id=MessageId}, #mqtt_subscribe{message_id=MessageId}) ->
	true;
is_same(#mqtt_suback{message_id=MessageId}, #mqtt_suback{message_id=MessageId}) ->
	true;
is_same(#mqtt_unsubscribe{message_id=MessageId}, #mqtt_unsubscribe{message_id=MessageId}) ->
	true;
is_same(#mqtt_unsuback{message_id=MessageId}, #mqtt_unsuback{message_id=MessageId}) ->
	true;
is_same(_, _) ->
	false.

-spec degrade(mqtt_qos(), mqtt_qos()) -> mqtt_qos().
degrade(exactly_once, exactly_once) ->
	exactly_once;
degrade(exactly_once, at_least_once) ->
	at_least_once;
degrade(at_least_once, exactly_once) ->
	at_least_once;
degrade(at_least_once, at_least_once) ->
	at_least_once;
degrade(_, _) ->
	at_most_once.