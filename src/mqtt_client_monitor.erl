%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Keeps spawning clients under mqtt_client_sup.
%%%
%%% Created : Aug 11, 2013
%%% -------------------------------------------------------------------
-module(mqtt_client_monitor).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

-export([start/1, stop/0, max_cps/0, max_cps/1, start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("props_to_record.hrl").

-define(MIN_TIMEOUT, 10).

-record(?MODULE, {mfa = {mqtt_client, start, [[]]},
				  max_cps = 10, % max clients per second
				  range = {1, 100}, % client_id range,
				  continue,
				  id_fun = fun(N) -> % client_id construction function
				  			   list_to_binary(io_lib:format("~23..0B", [N]))
				  		   end
				 }).

%% @doc Start a client monitor that tries to keep given number of clients running.
%%  The monitor itself is under control of the top level supervisor.
%%  While running, it keeps spawning clients with given strategy.
%%  The clients spawned by the monitor go under control of the mqtt_client_sup.
%% Parameters:
%%  {mfa, mfa()}: client specification
%%  {max_cps, pos_integer()}: maximum clients per second
%%  {range, {integer(), integer()}}: client id range
%%  {id_fun, fun/1}: client id formatter
start(Props) ->
	Spec = {?MODULE, {?MODULE, start_link, [Props]}, transient, brutal_kill, worker, dynamic},
	supervisor:start_child(fubar_sup, Spec).

%% @doc Stop the client monitor.
stop() ->
	% Try stopping under the top level supervisor.
	case supervisor:terminate_child(fubar_sup, ?MODULE) of
		ok ->
			supervisor:delete_child(fubar_sup, ?MODULE);
		{error, not_found} ->
			% The server is started in standalone mode.
			% Try sending a stop event.
			gen_server:cast(whereis(?MODULE), stop);
		Error ->
			Error
	end.

%% @doc Get maximum clients per second.
max_cps() ->
	gen_server:call(whereis(?MODULE), max_cps).

%% @doc Set maximum clients per second.
%% Parameters:
%%  pos_integer():
max_cps(Value) ->
	gen_server:call(whereis(?MODULE), {max_cps, Value}).

%% @doc Start an independent client monitor process.
start_link(Props) ->
	State = ?PROPS_TO_RECORD(Props ++ fubar:settings(?MODULE), ?MODULE),
	gen_server:start_link({local, ?MODULE}, ?MODULE, State, []).

% -----------------------------------------------------------------------------
% gen_server callbacks
% -----------------------------------------------------------------------------

init(State) ->
	{ok, State, schedule(State)}.

handle_call(max_cps, _From, State) ->
	{reply, {ok, State#?MODULE.max_cps}, State, schedule(State)};
handle_call({max_cps, Value}, _From, State) ->
	State1 = State#?MODULE{max_cps = Value},
	{reply, ok, State1, schedule(State1)};
handle_call(Message, From, State) ->
	lager:warning("unknown message ~p from ~p", [Message, From]),
	{reply, ok, State, schedule(State)}.

handle_cast(stop, State) ->
	{stop, normal, State};
handle_cast(Event, State) ->
	lager:warning("unknown event ~p", [Event]),
	{noreply, State, schedule(State)}.

handle_info(timeout, State) ->
	% lager:info("tick"),
	N = ceiling(?MIN_TIMEOUT * State#?MODULE.max_cps / 1000),
	{From, To} = State#?MODULE.range,
	{noreply, State#?MODULE{continue=case try_spawn(State#?MODULE.mfa, N, State#?MODULE.id_fun,
													case State#?MODULE.continue of
														undefined -> From;
														Continue -> Continue
													end, To) of
										 {ok, Next} -> Next;
										 _ -> undefined
									 end}, schedule(State)};
handle_info(Info, State) ->
	lager:warning("unknown info ~p", [Info]),
	{noreply, State, schedule(State)}.

terminate(Reason, State) ->
	lager:debug("terminate ~p when ~p", [Reason, State]),
	ok.

code_change(_, State, _) ->
	{ok, State}.

% -----------------------------------------------------------------------------
% Internal functions
% -----------------------------------------------------------------------------
try_spawn(_MFA, 0, _Id, From, _To) ->
	{ok, From};
try_spawn(_MFA, _N, _Id, From, To) when From > To ->
	ok;
try_spawn({M, F, A}, N, Id, From, To) ->
	ClientId = Id(From),
	case M:F([{client_id, ClientId} | A]) of
		{ok, _} ->
			try_spawn({M, F, A}, N-1, Id, From+1, To);
		_ ->
			try_spawn({M, F, A}, N, Id, From+1, To)
	end.

schedule(State) ->
	T = 1000 / State#?MODULE.max_cps,
	case T < ?MIN_TIMEOUT of
		true -> ?MIN_TIMEOUT;
		_ -> erlang:round(T)
	end.

ceiling(F) ->
	case erlang:trunc(F) of
		N when N < F -> N + 1;
		N -> N
	end.
