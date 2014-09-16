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
-behavior(mqtt_protocol).

%%
%% Exports
%%
-export([mnesia/1, get_address/0, get_address/1, set_address/1, apply_setting/1]).

%%
%% mqtt_protocol callbacks
%%
-export([init/1, handle_message/2, handle_event/2, terminate/2]).

-include("fubar.hrl").
-include("mqtt.hrl").
-include("props_to_record.hrl").

%% @doc Server address table schema
-record(mqtt_addr, {node = '_' :: node(),
					address = '_' :: string()}).

%% Auto start-up attributes
-create_mnesia_tables({mnesia, [create_tables]}).
-merge_mnesia_tables({mnesia, [merge_tables]}).
-split_mnesia_tables({mnesia, [split_tables]}).
-apply_setting(apply_setting).

-define(MNESIA_TIMEOUT, 10000).

%% @doc Mnesia table manipulations.
mnesia(create_tables) ->
	mnesia:create_table(mqtt_addr, [{attributes, record_info(fields, mqtt_addr)},
									{ram_copies, [node()]}, {type, set}]),
	ok = mnesia:wait_for_tables([mqtt_addr], ?MNESIA_TIMEOUT),
	mnesia(verify_tables);
mnesia(merge_tables) ->
	{atomic, ok} = mnesia:add_table_copy(mqtt_addr, node(), ram_copies),
	mnesia(verify_tables);
mnesia(split_tables) ->
	mnesia:del_table_copy(mqtt_addr, node());
mnesia(verify_tables) ->
	Settings = fubar:settings(?MODULE),
	set_address(proplists:get_value(address, Settings, "tcp://127.0.0.1:1883")).

apply_setting({address, Address}) ->
	set_address(Address);
apply_setting(_) ->
	ok.

%% @doc Get address of this node.
-spec get_address() -> {ok, string()} | {error, not_found}.
get_address() ->
	get_address(node()).

%% @doc Get address of a node.
-spec get_address(node()) -> {ok, string()} | {error, not_found}.
get_address(Node) ->
	case mnesia:dirty_read(mqtt_addr, Node) of
		[#mqtt_addr{address=Address}] -> Address;
		[] -> {error, not_found}
	end.

%% @doc Set address of this node.
-spec set_address(string()) -> ok.
set_address(Address) ->
	mnesia:dirty_write(#mqtt_addr{node=node(), address=Address}).	

-define(KEEPALIVE_MULTIPLIER, 2000).

-define (CONTEXT, ?MODULE).

%% mqtt_protocol context
-record(?CONTEXT, {
		client_id :: binary(),
		auth :: module(),
		session :: pid(),
		valid_keep_alive = {1800, 3600} :: {MinSec :: integer(), MaxSec :: integer()},
		when_overloaded = drop :: drop | accept,
		overloaded=false,
		load_balancing = none,
		timeout = 10000 :: timeout(),
		timestamp :: timestamp()
}).

-type context() :: #?CONTEXT{}.

-spec init(params()) -> {noreply, context(), timeout()}.
init(Params) ->
	Default = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?CONTEXT),
	Context = ?PROPS_TO_RECORD(Params, ?CONTEXT, Default)(),
	lager:debug("initializing with ~p", [Context]),
	% Don't respond anything against tcp connection and apply small initial timeout.
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout}.
	% {ok, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout}.

-spec handle_message(mqtt_message(), context()) ->
		  {reply, mqtt_message(), context(), timeout()} |
		  {noreply, context(), timeout()} |
		  {stop, Reason :: term()}.
handle_message(Message=#mqtt_connect{protocol= <<"MQIsdp">>, version=3, client_id=ClientId},
			   Context=#?CONTEXT{session=undefined}) ->
	lager:info("~p MSG IN ~p", [ClientId, Message]),
	mqtt_stat:transient(mqtt_connect),
	case {Context#?CONTEXT.overloaded, Context#?CONTEXT.load_balancing,
			Context#?CONTEXT.when_overloaded, Message#mqtt_connect.max_recursion > 0} of
		{true, _, drop, false} ->
			drop(Message, Context);
		{true, none, drop, _} ->
			drop(Message, Context);
		{_, Node, _, true} when Node =/= none ->
			offload(Message, get_address(Node), Context);
		_ ->
			accept(Message, Context)
	end;
handle_message(Message=#mqtt_connect{client_id=ClientId},
				Context=#?CONTEXT{session=undefined})->
	lager:info("~p MSG IN ~p", [ClientId, Message]),
	mqtt_stat:transient(mqtt_connect),
	Reply = mqtt:connack([{code, incompatible}]),
	mqtt_stat:transient(mqtt_connack),
	lager:info("~p MSG OUT ~p", [ClientId, Reply]),
	{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, 0};
handle_message(Message, Context=#?CONTEXT{session=undefined}) ->
	% All the other messages are not allowed without session.
	lager:warning("illegal MSG IN ~p", [Message]),
	{stop, normal, Context#?CONTEXT{timestamp=os:timestamp()}};
handle_message(Message=#mqtt_pingreq{}, Context) ->
	% Reflect ping and refresh timeout.
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_pingreq),
	Reply = #mqtt_pingresp{},
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Reply]),
	mqtt_stat:transient(mqtt_pingresp),
	{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_publish{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	case Message#mqtt_publish.dup of
		false ->
			case Message#mqtt_publish.qos of
				at_most_once -> mqtt_stat:transient(mqtt_publish_0_in);
				at_least_once -> mqtt_stat:transient(mqtt_publish_1_in);
				exactly_once -> mqtt_stat:transient(mqtt_publish_2_in);
				_ -> mqtt_stat:transient(mqtt_publish_3_in)
			end;
		_ ->
			ok
	end,
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_puback{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_puback_in),
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_pubrec{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_pubrec_in),
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_pubrel{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_pubrel_in),
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_pubcomp{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_pubcomp_in),
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_subscribe{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	case Message#mqtt_subscribe.dup of
		false -> mqtt_stat:transient(mqtt_subscribe);
		_ -> ok
	end,
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_unsubscribe{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	case Message#mqtt_unsubscribe.dup of
		false -> mqtt_stat:transient(mqtt_unsubscribe);
		_ -> ok
	end,
	Session ! Message,
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_message(Message=#mqtt_disconnect{}, Context=#?CONTEXT{session=Session}) ->
	lager:info("~p MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_disconnect),
	mqtt_session:stop(Session),
	{stop, normal, Context#?CONTEXT{timestamp=os:timestamp()}};
handle_message(Message, Context) ->
	lager:warning("~p unknown MSG IN ~p", [Context#?CONTEXT.client_id, Message]),
	mqtt_stat:transient(mqtt_unknown_in),
	{noreply, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout}.

-spec handle_event(Event :: term(), context()) ->
		  {reply, mqtt_message(), context(), timeout()} |
		  {noreply, context(), timeout()} |
		  {stop, Reason :: term(), context()}.
handle_event(timeout, Context=#?CONTEXT{client_id=ClientId}) ->
	% General timeout
	case ClientId of
		undefined -> ok;
		_ -> lager:info("~p timed out", [ClientId])
	end,
	{stop, normal, Context};
handle_event({stop, From}, Context=#?CONTEXT{client_id=ClientId}) ->
	lager:debug("~p stop signal from ~p", [ClientId, From]),
	{stop, normal, Context};
handle_event(Event, Context=#?CONTEXT{session=undefined}) ->
	lager:error("~p who sent this - ~p?", [Context#?CONTEXT.client_id,  Event]),
	{stop, normal, Context};
handle_event(Event=#mqtt_publish{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	case Event#mqtt_publish.dup of
		false ->
			case Event#mqtt_publish.qos of
				at_most_once -> mqtt_stat:transient(mqtt_publish_0_out);
				at_least_once -> mqtt_stat:transient(mqtt_publish_1_out);
				exactly_once -> mqtt_stat:transient(mqtt_publish_2_out);
				_ -> mqtt_stat:transient(mqtt_publish_3_out)
			end;
		_ ->
			ok
	end,
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_puback{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	mqtt_stat:transient(mqtt_puback_out),
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_pubrec{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	mqtt_stat:transient(mqtt_pubrec_out),
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_pubrel{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	mqtt_stat:transient(mqtt_pubrel_out),
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_pubcomp{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	mqtt_stat:transient(mqtt_pubcomp_out),
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_suback{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	mqtt_stat:transient(mqtt_suback),
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event=#mqtt_unsuback{}, Context) ->
	lager:info("~p MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	mqtt_stat:transient(mqtt_unsuback),
	{reply, Event, Context#?CONTEXT{timestamp=os:timestamp()}, Context#?CONTEXT.timeout};
handle_event(Event, Context) ->
	lager:warning("~p unknown MSG OUT ~p", [Context#?CONTEXT.client_id, Event]),
	{noreply, Context, timeout(Context#?CONTEXT.timeout, Context#?CONTEXT.timestamp)}.

-spec terminate(Reason :: term(), context()) -> Reason :: term().
terminate(Reason, Context) ->
	lager:debug("~p terminating", [Context#?CONTEXT.client_id]),
	case Reason of
		#mqtt_publish{} -> Context#?CONTEXT.session ! {recover, Reason};
		#mqtt_puback{} -> Context#?CONTEXT.session ! {recover, Reason};
		_ -> ok
	end,
	normal.

%%
%% Local Functions
%%
accept(Message=#mqtt_connect{}, Context=#?CONTEXT{auth=undefined}) ->
	bind_session(Message, Context);
accept(Message=#mqtt_connect{client_id=ClientId},
		Context=#?CONTEXT{auth=Auth, timeout=Timeout, timestamp=Timestamp}) ->
	case Message#mqtt_connect.username of
		undefined ->
			% Give another chance to connect with right credential again.
			lager:warning("~p no username", [ClientId]),
			Reply = mqtt:connack([{code, unauthorized}]),
			lager:info("~p MSG OUT ~p", [ClientId, Reply]),
			mqtt_stat:transient(mqtt_connack),
			{reply, Reply, Context, timeout(Timeout, Timestamp)};
		Username ->
			% Connection with credential.
			case Auth:verify(Username, Message#mqtt_connect.password) of
				ok ->
					% The client is authorized.
					% Now bind with the session or create a new one.
					lager:debug("~p authorized ~p", [ClientId, Username]),
					bind_session(Message, Context);
				{error, not_found} ->
					lager:warning("~p wrong username ~p", [ClientId, Username]),
					Reply = mqtt:connack([{code, forbidden}]),
					lager:info("~p MSG OUT ~p", [ClientId, Reply]),
					mqtt_stat:transient(mqtt_connack),
					{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, 0};
				{error, forbidden} ->
					lager:warning("~p wrong password ~p", [ClientId, Username]),
					Reply = mqtt:connack([{code, forbidden}]),
					lager:info("~p MSG OUT ~p", [ClientId, Reply]),
					mqtt_stat:transient(mqtt_connack),
					{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, 0};
				Error ->
					lager:error("~p error ~p in ~p:verify/2", [ClientId, Error, Auth]),
					Reply = mqtt:connack([{code, unavailable}]),
					lager:info("~p MSG OUT ~p", [ClientId, Reply]),
					mqtt_stat:transient(mqtt_connack),
					{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, 0}
			end
	end.

drop(#mqtt_connect{client_id=ClientId}, Context) ->
	lager:info("~p overloaded", [ClientId]),
	Reply = mqtt:connack([{code, unavailable}]),
	lager:info("~p MSG OUT ~p", [ClientId, Reply]),
	mqtt_stat:transient(mqtt_connack),
	{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, 0}.

offload(#mqtt_connect{client_id=ClientId, max_recursion=MaxRecursion}, Addr, Context) ->
	lager:info("~p offloading to ~s", [ClientId, Addr]),
	Reply = mqtt:connack([{code, alt_server}, {alt_server, list_to_binary(Addr)}, {max_recursion, MaxRecursion-1}]),
	lager:info("~p MSG OUT ~p", [ClientId, Reply]),
	mqtt_stat:transient(mqtt_connack),
	{reply, Reply, Context#?CONTEXT{timestamp=os:timestamp()}, 0}.

timeout(infinity, _) ->
	infinity;
timeout(Milliseconds, Timestamp) ->
	Elapsed = timer:now_diff(os:timestamp(), Timestamp) div 1000,
	case Milliseconds > Elapsed of
		true -> Milliseconds - Elapsed;
		_ -> 0
	end.

bind_session(Message=#mqtt_connect{client_id=ClientId, username=Username}, Context) ->
	% Once bound, the session will detect process termination.
	% Timeout value should be set as requested.
	Will = case Message#mqtt_connect.will_topic of
			   undefined -> undefined;
			   Topic -> {Topic, Message#mqtt_connect.will_message,
						 Message#mqtt_connect.will_qos, Message#mqtt_connect.will_retain}
		   end,
	case catch mqtt_session:bind(ClientId, Username, Will) of
		{ok, Session} ->
			lager:debug("~p session bound ~p", [ClientId, Session]),
			KeepAlive = determine_keep_alive(Message#mqtt_connect.keep_alive, Context#?CONTEXT.valid_keep_alive),
			% Set timeout as 1.5 times the keep-alive.
			Timeout = KeepAlive*?KEEPALIVE_MULTIPLIER,
			Reply = case KeepAlive =:= Message#mqtt_connect.keep_alive of
						true -> mqtt:connack([{code, accepted}]);
						% MQTT extension: server may suggest different keep-alive.
						_ -> mqtt:connack([{code, accepted}, {extra, <<KeepAlive:16/big-unsigned>>}])
					end,
			case Message#mqtt_connect.clean_session of
				true -> mqtt_session:clean(Session);
				_ -> ok
			end,
			lager:info("~p MSG OUT ~p", [ClientId, Reply]),
			mqtt_stat:transient(mqtt_connack),
			{reply, Reply,
			 Context#?CONTEXT{client_id=ClientId, session=Session, timeout=Timeout, timestamp=os:timestamp()}, Timeout};
		{'EXIT', Reason} ->
			lager:error("~p exception ~p binding session", [ClientId, Reason]),
			Reply = mqtt:connack([{code, unavailable}]),
			lager:info("~p MSG OUT ~p", [ClientId, Reply]),
			mqtt_stat:transient(mqtt_connack),
			% Timeout immediately to close just after reply.
			{reply, Reply, Context#?CONTEXT{client_id=ClientId, timestamp=os:timestamp()}, 0};
		Error ->
			lager:error("~p error ~p binding session", [ClientId, Error]),
			Reply = mqtt:connack([{code, unavailable}]),
			lager:info("~p MSG OUT ~p", [ClientId, Reply]),
			mqtt_stat:transient(mqtt_connack),
			% Timeout immediately to close just after reply.
			{reply, Reply, Context#?CONTEXT{client_id=ClientId, timestamp=os:timestamp()}, 0}
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
-include_lib("eunit/include/eunit.hrl").
-endif.
