%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : A reference MQTT client.
%%%
%%% Created : May 25, 2014
%%% -------------------------------------------------------------------
-module(mqtt_client_simple).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(mqtt_client).

%%
%% Helper interfaces.
%%
-export([connect/1, reconnect/1, disconnect/1, stop/1, last_message/1]).

%%
%% mqtt_client behavior callbacks.
%%
-export([handle_connected/1, handle_disconnected/1, handle_message/2, handle_event/2]).

%%
%% Imports and definitions.
%%
-include("mqtt.hrl").
-include("props_to_record.hrl").

-define(STATE, ?MODULE).

-record(?STATE, {
	client_id,
	last_message
}).

%%
%% Helper implementations.
%%

%% @doc Connect a simple MQTT client.
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
connect(Params) ->
	State = ?PROPS_TO_RECORD(Params, ?STATE),
	mqtt_client:connect([{handler, ?MODULE}, {handler_state, State} |
			Params] ++ fubar:settings(?MODULE)).

%% @doc Reconnect a simple MQTT client.
reconnect(Id) ->
	mqtt_client:reconnect(Id).

%% @doc Disconnect a simple MQTT client.
disconnect(Id) ->
	mqtt_client:disconnect(Id).

%% @doc Stop an MQTT client.
stop(Id) ->
	mqtt_client:stop(Id).

%% @doc Get the last message received.
last_message(Id) ->
	case mqtt_client_sup:get(Id) of
		{ok, Pid} ->
			Pid ! {last_message, self()},
			receive
				Msg -> {ok, Msg}
			after 5000 -> {error, timeout}
			end;
		Error ->
			Error
	end.

%%
%% mqtt_client behavior implementations.
%%
-spec handle_connected(#?STATE{}) -> #?STATE{}.
handle_connected(State=#?STATE{client_id=ClientId}) ->
	lager:notice("~p connected", [ClientId]),
	State.

-spec handle_disconnected(#?STATE{}) -> any().
handle_disconnected(#?STATE{client_id=ClientId}) ->
	lager:notice("~p disconnected", [ClientId]).

-spec handle_message(mqtt_message(), #?STATE{}) -> #?STATE{}.
handle_message(Message, State=#?STATE{client_id=ClientId}) ->
	lager:notice("~p received ~p", [ClientId, Message]),
	State#?STATE{last_message=Message#mqtt_publish.payload}.

-spec handle_event(Event :: any(), #?STATE{}) -> #?STATE{}.
handle_event({last_message, Pid}, State) ->
	Pid ! State#?STATE.last_message,
	State.
