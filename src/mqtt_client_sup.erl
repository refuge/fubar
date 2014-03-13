%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar supervisor callback.
%%%
%%% Created : Nov 28, 2012
%%% -------------------------------------------------------------------
-module(mqtt_client_sup).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(supervisor).

%%
%% Exports
%%
-export([
	start_link/0,
	stop/0,
	start_child/2,
	restart_child/1,
	stop_child/1,
	get/1, all/0, connected/0, disconnected/0
]).

-export([init/1]).

-include("fubar.hrl").

-define(MAX_R, 10000).
-define(MAX_T, 1).

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Stop the supervisor.
-spec stop() -> ok.
stop() ->
	erlang:exit(erlang:whereis(?MODULE), normal).

%% @doc Start an mqtt client under supervision.
-spec start_child(module(), proplist(atom(), term())) -> pid() | {error, term()}.
start_child(Module, Props) ->
	Id = proplists:get_value(client_id, Props),
	Spec = {Id, {Module, start_link, [Props]}, transient, brutal_kill, worker, dynamic},
	case supervisor:start_child(?MODULE, Spec) of
		{ok, Pid} ->
			Pid;
		{error, {already_started, Pid}} ->
			Pid;
		{error, already_present} ->
			supervisor:delete_child(?MODULE, Id),
			start_child(Module, Props);
		Error ->
			Error
	end.

-spec restart_child(term()) -> pid() | {error, term()}.
restart_child(Id) ->
	case supervisor:restart_child(?MODULE, Id) of
		{ok, Pid} -> Pid;
		Error -> Error
	end.

%% @doc Stop an mqtt client under supervision.
-spec stop_child(binary()) -> ok | {error, term()}.
stop_child(Id) ->
	supervisor:terminate_child(?MODULE, Id).

%% @doc Get a client's pid if running.
-spec get(Id :: term()) -> pid() | {error, disconnected | not_exists}.
get(Id) ->
	case lists:keyfind(Id, 1, supervisor:which_children(?MODULE)) of
		false -> {error, not_exists};
		{Id, Pid, worker, _} when erlang:is_pid(Pid) -> Pid;
		{Id, undefined, worker, _} -> undefined
	end.

%% @doc Get all the clients under supervision.
-spec all() -> [{term(), pid()}].
all() ->
	[{Id, Pid} || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
				  Type =:= worker].

%% @doc Get running clients under supervision.
-spec connected() -> [{term(), pid()}].
connected() ->
	[{Id, Pid} || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
				  Pid =/= undefined,
				  Type =:= worker].

%% @doc Get running clients under supervision.
-spec disconnected() -> [term()].
disconnected() ->
	[Id || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
		   Pid =:= undefined,
		   Type =:= worker].

%%
%% Supervisor callbacks
%%
init(_) ->
	{ok, {{one_for_one, ?MAX_R, ?MAX_T}, []}}.
