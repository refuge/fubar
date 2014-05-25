%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Types for MQTT. 
%%%
%%% Created : Oct 26, 2012
%%% -------------------------------------------------------------------
-type mqtt_command() :: mqtt_reserved |
		  mqtt_connect | mqtt_connack |
		  mqtt_publish | mqtt_puback | mqtt_pubrec | mqtt_pubrel | mqtt_pubcomp |
		  mqtt_subscribe | mqtt_suback | mqtt_unsubscribe | mqtt_unsuback |
		  mqtt_pingreq | mqtt_pingresp |
		  mqtt_disconnect.
-type mqtt_qos() :: at_most_once | at_least_once | exactly_once.

-record(mqtt_header, {type :: mqtt_command(),
					  dup = false :: boolean(),
					  qos = at_most_once :: mqtt_qos(),
					  retain = false :: boolean(),
					  size :: undefined | non_neg_integer()}).

-record(mqtt_reserved, {dup = false :: boolean(),
						qos = at_most_once :: mqtt_qos(),
						retain = false :: boolean(),
						extra = <<>> :: binary()}).

-record(mqtt_connect, {protocol = <<"MQIsdp">> :: binary(),
					   version = 3 :: pos_integer(),
					   username = <<>> :: binary(),
					   password = <<>> :: binary(),
					   will_retain = false :: boolean(),
					   will_qos = at_most_once :: mqtt_qos(),
					   will_topic :: undefined | binary(),
					   will_message :: undefined | binary(),
					   clean_session = false,
					   keep_alive = 600 :: pos_integer(),
					   client_id = <<>> :: binary(),
					   max_recursion = 0 :: integer(),
					   extra = <<>> :: binary()}).

-type mqtt_connack_code() :: accepted | incompatible | id_rejected | unavailable |
		forbidden | unauthorized | alt_server.

-record(mqtt_connack, {code = accepted :: mqtt_connack_code(),
					   alt_server = <<>> :: binary(),
					   max_recursion = 0 :: integer(),
					   extra = <<>> :: binary()}).

-record(mqtt_publish, {topic = <<>> :: binary(),
					   message_id :: undefined | pos_integer(),
					   dup = false:: boolean(),
					   qos = at_most_once :: mqtt_qos(),
					   retain = false :: boolean(),
					   payload = <<>> :: binary()}).

-record(mqtt_puback, {message_id :: pos_integer(),
					  extra = <<>> :: binary()}).

-record(mqtt_pubrec, {message_id :: pos_integer(),
					  extra = <<>> :: binary()}).

-record(mqtt_pubrel, {message_id :: pos_integer(),
					  extra = <<>> :: binary()}).

-record(mqtt_pubcomp, {message_id :: pos_integer(),
					   extra = <<>> :: binary()}).

-record(mqtt_subscribe, {message_id :: pos_integer(),
						 topics = [] :: [{binary(), mqtt_qos()}],
						 dup = false :: boolean(),
						 qos = at_least_once :: mqtt_qos(),
						 extra = <<>> :: binary()}).

-record(mqtt_suback, {message_id :: pos_integer(),
					  qoss = [] :: [mqtt_qos()],
					  extra = <<>> :: binary()}).

-record(mqtt_unsubscribe, {message_id :: pos_integer(),
						   topics = [] :: [binary()],
						   dup = false :: boolean(),
						   qos = at_least_once :: mqtt_qos(),
						   extra = <<>> :: binary()}).

-record(mqtt_unsuback, {message_id :: pos_integer(),
						extra = <<>> :: binary()}).

-record(mqtt_pingreq, {extra = <<>> :: binary()}).

-record(mqtt_pingresp, {extra = <<>> :: binary()}).

-record(mqtt_disconnect, {extra = <<>> :: binary()}).

-type mqtt_message() :: #mqtt_reserved{} | #mqtt_connect{} | #mqtt_connack{} |
		#mqtt_publish{} | #mqtt_puback{} | #mqtt_pubrec{} | #mqtt_pubrel{} | #mqtt_pubcomp{} |
		#mqtt_subscribe{} | #mqtt_suback{} | #mqtt_unsubscribe{} | #mqtt_unsuback{} |
		#mqtt_pingreq{} | #mqtt_pingresp{} |
		#mqtt_disconnect{}.
