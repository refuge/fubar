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
%% Includes
%%
-include("fubar.hrl").

%%
%% Macros
%%
-define(MAX_R, 100).
-define(MAX_T, 5).

%%
%% Exports
%%
-export([start_link/0, start_child/2, start_child/3,
		 restart_child/1, restart_child/2, stop_child/1,
		 all/0, running/0, stopped/0]).

-export([init/1]).

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start an mqtt client under supervision.
-spec start_child(module(), proplist(atom(), term())) -> pid() | {error, reason()}.
start_child(Module, Props) ->
	Id = proplists:get_value(client_id, Props),
	Spec = {Id, {Module, start_link, [Props]}, transient, brutal_kill, worker, dynamic},
	case supervisor:start_child(?MODULE, Spec) of
		{ok, Pid} -> Pid;
		Error -> Error
	end.

-spec start_child(module(), proplist(atom(), term()), timeout()) -> pid() | {error, reason()}.
start_child(Module, Props, Millisec) ->
	timer:sleep(Millisec),
	start_child(Module, Props).

-spec restart_child(term()) -> pid() | {error, reason()}.
restart_child(Id) ->
	case supervisor:restart_child(?MODULE, Id) of
		{ok, Pid} -> Pid;
		Error -> Error
	end.

-spec restart_child(term(), timeout()) -> pid() | {error, reason()}.
restart_child(Id, Millisec) ->
	timer:sleep(Millisec),
	restart_child(Id).

%% @doc Stop an mqtt client under supervision.
-spec stop_child(binary()) -> ok | {error, reason()}.
stop_child(Id) ->
	supervisor:terminate_child(?MODULE, Id),
	supervisor:delete_child(?MODULE, Id).

%% @doc Get all the clients under supervision.
-spec all() -> [{term(), pid()}].
all() ->
	[{Id, Pid} || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
				  Type =:= worker].

%% @doc Get running clients under supervision.
-spec running() -> [{term(), pid()}].
running() ->
	[{Id, Pid} || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
				  Pid =/= undefined,
				  Type =:= worker].

%% @doc Get running clients under supervision.
-spec stopped() -> [term()].
stopped() ->
	[Id || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
		   Pid =:= undefined,
		   Type =:= worker].

%%
%% Supervisor callbacks
%%
init(_) ->
	{ok, {{one_for_one, ?MAX_R, ?MAX_T}, []}}.
