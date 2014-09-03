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
	connect/2, reconnect/1, stop/1, disconnect/1,
	get/1, get_all/0, get_running/0, get_stopped/0
]).

-export([init/1]).

-include("fubar.hrl").

-define(MAX_R, 10000).
-define(MAX_T, 1).

%% @doc Start the supervisor.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Stop the supervisor.
-spec stop() -> ok.
stop() ->
	erlang:exit(erlang:whereis(?MODULE), normal).

%% @doc Connect an mqtt client.
-spec connect(module(), params()) -> {ok, pid()} | {error, reason()}.
connect(Module, Params) ->
	% Get client_id and use it as child id.
	Id = proplists:get_value(client_id, Params),
	Spec = {Id, {Module, start_link, [Params]}, transient, brutal_kill, worker, dynamic},
	case supervisor:start_child(?MODULE, Spec) of
		{ok, Pid} ->
			{ok, Pid};
		{error, {already_started, Pid}} ->
			{ok, Pid};
		{error, already_present} ->
			% If the child id is present but not running,
			% delete it and start the child again.
			supervisor:delete_child(?MODULE, Id),
			connect(Module, Params);
		Error ->
			Error
	end.

%% @doc Reconnect an mqtt client.
-spec reconnect(Id :: term()) -> {ok, pid()} | {error, reason()}.
reconnect(Id) ->
	case supervisor:restart_child(?MODULE, Id) of
		{ok, Pid} ->
			{ok, Pid};
		{error, {already_started, Pid}} ->
			{ok, Pid};
		Error ->
			Error
	end.

%% @doc Disconnect an mqtt_client.
-spec disconnect(Id :: term()) -> ok | {error, reason()}.
disconnect(Id) ->
	case ?MODULE:get(Id) of
		{ok, disconnected} ->
			{error, already_disconnected};
		{ok, Pid} ->
			mqtt_client:send(Pid, mqtt:disconnect([]));
		Error ->
			Error
	end.

%% @doc Stop an mqtt_client without disconnect.
-spec stop(Id :: term()) -> ok | {error, reason()}.
stop(Id) ->
	supervisor:terminate_child(?MODULE, Id).

%% @doc Get a client's pid if running.
-spec get(Id :: term()) -> {ok, pid()} | {error, stopped | not_exists}.
get(Id) ->
	case lists:keyfind(Id, 1, supervisor:which_children(?MODULE)) of
		false ->
			{error, not_exists};
		{Id, undefined, worker, _} ->
			% Found an id which is not running.
			{ok, disconnected};
		{Id, Pid, worker, _} ->
			{ok, Pid};
		Error ->
			Error
	end.

%% @doc Get all the clients under supervision.
-spec get_all() -> [{term(), pid()}].
get_all() ->
	[{Id, Pid} || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
				  Type =:= worker].

%% @doc Get running clients under supervision.
-spec get_running() -> [{term(), pid()}].
get_running() ->
	[{Id, Pid} || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
				  Pid =/= undefined,
				  Type =:= worker].

%% @doc Get stopped clients under supervision.
-spec get_stopped() -> [term()].
get_stopped() ->
	[Id || {Id, Pid, Type, _} <- supervisor:which_children(?MODULE),
		   Pid =:= undefined,
		   Type =:= worker].

%%
%% Supervisor callbacks
%%
init(_) ->
	{ok, {{one_for_one, ?MAX_R, ?MAX_T}, []}}.
