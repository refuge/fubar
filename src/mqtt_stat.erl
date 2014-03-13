%% @author skplanet
%% @doc @todo Add description to mqtt_stat.
-module(mqtt_stat).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ====================================================================
%% API functions
%% ====================================================================
-export([start_link/1, tid/0, delete/1, transient/1, join/1, leave/1, interval/0, interval/1, flush/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("props_to_record.hrl").

-define(LAGER_RESTART_THRESHOLD, 1000).

%% ====================================================================
%% Behavioural functions 
%% ====================================================================
-record(?MODULE, {tid,
				  flush = fun({Key, Value}, Tid) ->
								  ?MODULE:flush(Key, Value),
								  Tid;
							 ({Key, Value, transient}, Tid) ->
								  ?MODULE:flush(Key, Value),
								  ets:update_element(Tid, Key, {2, 0}),
								  Tid
						  end,
				  interval = 60000,
				  timestamp}).

start_link(Props) ->
	State = ?PROPS_TO_RECORD(Props++fubar:settings(?MODULE), ?MODULE),
	gen_server:start_link(?MODULE, State, []).

tid() ->
	gen_server:call(erlang:whereis(?MODULE), tid).

delete(Key) ->
	ets:delete(?MODULE:tid(), Key).

transient(Key) ->
	gen_server:cast(erlang:whereis(?MODULE), {transient, Key}).

join(Key) ->
	gen_server:cast(erlang:whereis(?MODULE), {join, Key}).

leave(Key) ->
	gen_server:cast(erlang:whereis(?MODULE), {leave, Key}).

interval() ->
	gen_server:call(erlang:whereis(?MODULE), interval).

interval(Millisec) ->
	gen_server:call(erlang:whereis(?MODULE), {interval, Millisec}).

%% init/1
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:init-1">gen_server:init/1</a>
-spec init(Args :: term()) -> Result when
	Result :: {ok, State}
			| {ok, State, Timeout}
			| {ok, State, hibernate}
			| {stop, Reason :: term()}
			| ignore,
	State :: term(),
	Timeout :: non_neg_integer() | infinity.
%% ====================================================================
init(State) ->
	lager:notice("mqtt stat collector init with ~p", [State]),
	erlang:register(?MODULE, self()),
    {ok, State#?MODULE{timestamp=os:timestamp()}, State#?MODULE.interval}.


%% handle_call/3
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:handle_call-3">gen_server:handle_call/3</a>
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, State :: term()) -> Result when
	Result :: {reply, Reply, NewState}
			| {reply, Reply, NewState, Timeout}
			| {reply, Reply, NewState, hibernate}
			| {noreply, NewState}
			| {noreply, NewState, Timeout}
			| {noreply, NewState, hibernate}
			| {stop, Reason, Reply, NewState}
			| {stop, Reason, NewState},
	Reply :: term(),
	NewState :: term(),
	Timeout :: non_neg_integer() | infinity,
	Reason :: term().
%% ====================================================================
handle_call(tid, _From, State=#?MODULE{tid=Tid}) ->
	{reply, Tid, State, sleep(State#?MODULE.timestamp, State#?MODULE.interval)};
handle_call({interval, Millisec}, _From, State=#?MODULE{}) ->
	{reply, ok, State#?MODULE{interval=Millisec}, sleep(State#?MODULE.timestamp, Millisec)};
handle_call(interval, _From, State=#?MODULE{interval=Interval}) ->
	{reply, Interval, State, sleep(State#?MODULE.timestamp, State#?MODULE.interval)};
handle_call(Request, From, State) ->
	lager:debug("unknown call ~p from ~p", [Request, From]),
    {reply, ok, State, sleep(State#?MODULE.timestamp, State#?MODULE.interval)}.


%% handle_cast/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:handle_cast-2">gen_server:handle_cast/2</a>
-spec handle_cast(Request :: term(), State :: term()) -> Result when
	Result :: {noreply, NewState}
			| {noreply, NewState, Timeout}
			| {noreply, NewState, hibernate}
			| {stop, Reason :: term(), NewState},
	NewState :: term(),
	Timeout :: non_neg_integer() | infinity.
%% ====================================================================
handle_cast({Type, Key}, State=#?MODULE{tid=Tid}) ->
	Inc = case Type of
			  leave -> -1;
			  _ -> 1
		  end,
	case catch ets:update_counter(Tid, Key, {2, Inc}) of
		{'EXIT', _} ->
			case Type of
				transient -> ets:insert(Tid, {Key, 1, Type});
				join -> ets:insert(Tid, {Key, 1});
				_ -> ets:insert(Tid, {Key, 0})
			end;
		_ ->
			ok
	end,
    {noreply, State, sleep(State#?MODULE.timestamp, State#?MODULE.interval)};
handle_cast(Msg, State) ->
	lager:debug("unknown cast ~p", [Msg]),
    {noreply, State, sleep(State#?MODULE.timestamp, State#?MODULE.interval)}.

%% handle_info/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:handle_info-2">gen_server:handle_info/2</a>
-spec handle_info(Info :: timeout | term(), State :: term()) -> Result when
	Result :: {noreply, NewState}
			| {noreply, NewState, Timeout}
			| {noreply, NewState, hibernate}
			| {stop, Reason :: term(), NewState},
	NewState :: term(),
	Timeout :: non_neg_integer() | infinity.
%% ====================================================================
handle_info(timeout, State=#?MODULE{tid=Tid, flush=F, interval=T}) ->
	Lager = whereis(lager_event),
	case catch process_info(Lager, message_queue_len) of
		{message_queue_len, N} when N > ?LAGER_RESTART_THRESHOLD ->
			% lager is overloaded and may cause system down
			exit(Lager, kill),
			application:stop(lager),
			application:start(lager),
			lager:critical("lager restart by ~p messages > threshold ~p", [N, ?LAGER_RESTART_THRESHOLD]);
		_ ->
			% lager might have stopped for some reason
			application:start(lager)
	end,
	lager:alert("--------BEGIN--------"),
	ets:foldl(F, Tid, Tid),
	?MODULE:flush(routes, mnesia:table_info(fubar_route, size)),
	?MODULE:flush(memory, erlang:memory(total)),
	lager:alert("---------END---------"),
	catch erlang:garbage_collect(whereis(mnesia_tm)), % periodic gc on mnesia_tm
	catch erlang:garbage_collect(whereis(lager_event)), % periodic gc on lager_event
	{noreply, State#?MODULE{timestamp=os:timestamp()}, T}; 
handle_info(Info, State) ->
	lager:debug("unknown info ~p", [Info]),
    {noreply, State, sleep(State#?MODULE.timestamp, State#?MODULE.interval)}.


%% terminate/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:terminate-2">gen_server:terminate/2</a>
-spec terminate(Reason, State :: term()) -> Any :: term() when
	Reason :: normal
			| shutdown
			| {shutdown, term()}
			| term().
%% ====================================================================
terminate(Reason, _State) ->
	unregister(?MODULE),
	lager:notice("mqtt stat collector terminate by ~p", [Reason]),
    ok.


%% code_change/3
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:code_change-3">gen_server:code_change/3</a>
-spec code_change(OldVsn, State :: term(), Extra :: term()) -> Result when
	Result :: {ok, NewState :: term()} | {error, Reason :: term()},
	OldVsn :: Vsn | {down, Vsn},
	Vsn :: term().
%% ====================================================================
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ====================================================================
%% Internal functions
%% ====================================================================
sleep(Then, Duration) ->
	Now = os:timestamp(),
	case Duration - timer:now_diff(Now, Then) div 1000 of
		T when T < 0 ->
			0;
		T ->
			T
	end.

flush(Key, Value) ->
	lager:alert("~p,~p", [Key, Value]).
