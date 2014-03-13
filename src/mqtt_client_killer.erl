%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Kills random clients under mqtt_client_sup.
%%%
%%% Created : Aug 10, 2013
%%% -------------------------------------------------------------------
-module(mqtt_client_killer).
-author("Sungjin Park <jinni.park@sk.com>").
-behavior(gen_server).

-export([start/1, start_link/1, stop/0, mri/0, mri/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("props_to_record.hrl").

-define(DEFAULT_TIMEOUT, 1000).
-define(MIN_TIMEOUT, 10).

-record(?MODULE, {mri = 1200 % mean reconnection interval
				  }).

%% @doc Start a client killer under the top level supervisor.
%% Parameters:
%%  {mri, pos_integer()}: mean reconnection interval
start(Props) ->
	Spec = {?MODULE, {?MODULE, start_link, [Props]}, transient, brutal_kill, worker, dynamic},
	supervisor:start_child(fubar_sup, Spec).

%% Stop the killer.
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

%% Get mean reconnection interval.
mri() ->
	gen_server:call(whereis(?MODULE), mri).

%% Set mean reconnection interval.
%% Parameters:
%%  pos_integer(): mean reconnection interval
mri(Value) ->
	gen_server:call(whereis(?MODULE), {mri, Value}).

%% @doc Start a killer independently.
start_link(Props) ->
	State = ?PROPS_TO_RECORD(Props ++ fubar:settings(?MODULE), ?MODULE),
	gen_server:start_link({local, ?MODULE}, ?MODULE, State, []).

% -----------------------------------------------------------------------------
% gen_server callbacks
% -----------------------------------------------------------------------------

init(State) ->
	random:seed(os:timestamp()),
	{ok, State, ?DEFAULT_TIMEOUT}.

handle_call(mri, _, State) ->
	{reply, {ok, State#?MODULE.mri}, State, ?DEFAULT_TIMEOUT};
handle_call({mri, Value}, _, State) ->
	{reply, ok, State#?MODULE{mri=Value}, ?DEFAULT_TIMEOUT};
handle_call(Message, From, State) ->
	lager:warning("unknown message ~p from ~p", [Message, From]),
	{reply, ok, State, ?DEFAULT_TIMEOUT}.

handle_cast(stop, State) ->
	% Legitimate stop event.
	{stop, normal, State};
handle_cast(Event, State) ->
	lager:warning("unknown event ~p", [Event]),
	{noreply, State, ?DEFAULT_TIMEOUT}.

handle_info(timeout, State) ->
	% Kill some of the clients under the client supervisor.
	Running = mqtt_client_sup:running(),
	L = erlang:length(Running),
	T = case L of
			0 -> ?MIN_TIMEOUT;
			_ -> State#?MODULE.mri / L * 1000
		end,
	{N, Timeout} = case {T < ?MIN_TIMEOUT, L} of
					   {_, 0} -> {0, ?MIN_TIMEOUT};
					   {true, _} -> {erlang:round(?MIN_TIMEOUT / T), ?MIN_TIMEOUT};
					   _ -> {1, erlang:round(T)}
				   end,
	Targets = [lists:nth(random:uniform(L), Running) || _ <- lists:seq(1, N)],
	lists:foreach(fun({Id, Client}) ->
					  lager:debug("kill ~p ~p", [Id, Client]),
					  catch exit(Client, kill)
				  end, Targets),
	{noreply, State, Timeout};
handle_info(Info, State) ->
	lager:warning("unknown info ~p", [Info]),
	{noreply, State}.

terminate(Reason, State) ->
	lager:debug("terminate ~p when ~p", [Reason, State]),
	ok.

code_change(_, State, _) ->
	{ok, State}.
