%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar utility functions.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(fubar).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Exported Functions
%%
-export([start/0, stop/0,						% application start/stop
		 state/0,								% get application state
		 load_config/0,							% load configuration from file
		 settings/1, settings/2,				% application environment getter/setter
		 create/1, set/2, get/2, timestamp/2	% fubar message manipulation
		]).

-include("fubar.hrl").
-include("props_to_record.hrl").

-define(APPLICATION, ?MODULE).

%% @doc Start application.
-spec start() -> ok | {error, Reason :: term()}.
start() ->
	application:load(?APPLICATION),
	error_logger:tty(false),
	% Start applications and dependencies and store the list in an ets
	% for later dependency management.
	ets:new(?APPLICATION, [named_table, public]),
	ensure_started(kernel),
	ensure_started(stdlib),
	ensure_started(sasl),
	ensure_started(lager),
	ensure_started(cpg),
	ensure_started(mnesia),
	ensure_started(ssl),
	ensure_started(ranch),
	ensure_started(cowboy),
	Res = application:start(?APPLICATION),
	% Let the dependency store persist with the top-level-supervisor.
	ets:setopts(?APPLICATION, [{heir, whereis(fubar_sup), ?APPLICATION}]),
	Res.

%% @doc Stop application.
-spec stop() -> ok | {error, Reason :: term()}.
stop() ->
	% Get application start up list and sort to stop them in order.
	Deps = lists:sort(fun([_, T1], [_, T2]) -> timer:now_diff(T1, T2) > 0 end,
					  ets:match(?APPLICATION, {'$1', '$2'})),
	ets:delete(?APPLICATION),
	application:stop(?APPLICATION),
	ensure_stopped(Deps),
	wait_for_stop(),
	halt().

%% @doc Get application state.
-spec state() -> {ok, params()} | {error, Reason :: term()}.
state() ->
	case lists:keyfind(?APPLICATION, 1, application:which_applications()) of
		false ->
			{error, "fubar not running"};
		{Name, Desc, Version} ->
			case catch supervisor:which_children(ranch_sup) of
				{'EXIT', _} ->
					{ok, [{name, Name}, {description, Desc}, {version, Version}]};
				Ranch ->
					Listeners = lists:foldl(fun({{ranch_listener_sup, Listener}, Pid, supervisor, _}, Acc) ->
													[{Listener, Pid} | Acc];
											   (_, Acc) ->
													Acc
											end, [], Ranch),
					{ok, [{name, Name}, {description, Desc}, {version, Version},
						  {listeners, listener_state(Listeners)},
						  {nodes, [node() | nodes()]},
						  {routes, mnesia:table_info(fubar_route, size)},
						  {memory, [{'MB', trunc(fubar_sysmon:memory()/1024/1024)},
						  			{load, fubar_sysmon:load()},
						  			{min_load, fubar_sysmon:min_load()}]}]}
			end
	end.

%% @doc Read fubar.config and apply.
-spec load_config() -> ok.
load_config() ->
	{ok, [Config]} = file:consult("fubar.config"),
	apply_config(Config).

%% @doc Get current settings for a module.
-spec settings(module()) -> params().
settings(Module) ->
	case application:get_env(?APPLICATION, Module) of
		{ok, Props} -> Props;
		_ -> []
	end.

%% @doc Update module settings.
%% The changes are not written to fubar.config
-spec settings(module(), param() | params()) -> ok.
settings(Module, {Key, Value}) ->
	Settings = settings(Module),
	NewSettings = replace({Key, Value}, Settings),
	application:set_env(?APPLICATION, Module, NewSettings),
	lists:foreach(
		fun
			({M, F, A}) -> M:F([{Key, Value} | A]);
			({F, A}) -> Module:F([{Key, Value} | A]);
			(F) -> Module:F({Key, Value})
		end,
		proplists:get_value(apply_setting, module_attributes_in(Module), []));
settings(Module, [{Key, Value} | T]) ->
	settings(Module, {Key, Value}),
	settings(Module, T);
settings(_, []) ->
	ok.

%% @doc Create a fubar.
-spec create(params()) -> fubar().
create(Props) ->
	set(Props, #fubar{}).

%% @doc Set fields in a fubar.
-spec set(params(), fubar()) -> fubar().
set(Props, Fubar=#fubar{}) ->
	Base = ?PROPS_TO_RECORD(Props, fubar, Fubar)(),
	case proplists:get_value(id, Props) of
		undefined ->
			Base;
		_ ->
			Now = os:timestamp(),
			Base#fubar{from = stamp(Base#fubar.from, Now),
					   via = stamp(Base#fubar.via, Now),
					   to = stamp(Base#fubar.to, Now)}
	end.

%% @doc Get a field or fields in a fubar.
-spec get(atom() | [atom()], fubar()) -> term() | [term()].
get([], #fubar{}) ->
	[];
get([Field | Rest], Fubar=#fubar{}) ->
	[get(Field, Fubar) | get(Rest, Fubar)];
get(id, #fubar{id=Value}) ->
	Value;
get(from, #fubar{from={Value, _}}) ->
	Value;
get(from, #fubar{from=Value}) ->
	Value;
get(via, #fubar{via={Value, _}}) ->
	Value;
get(via, #fubar{via=Value}) ->
	Value;
get(to, #fubar{to={Value, _}}) ->
	Value;
get(to, #fubar{to=Value}) ->
	Value;
get(payload, #fubar{payload=Value}) ->
	Value;
get(_, _=#fubar{}) ->
	undefined.

%% @doc Get timestamp of a field or fields in a fubar.
-spec timestamp(atom() | [atom()], fubar()) -> timestamp() | undefined.
timestamp([], #fubar{}) ->
	[];
timestamp([Field | Rest], Fubar=#fubar{}) ->
	[get(Field, Fubar) | get(Rest, Fubar)];
timestamp(from, #fubar{from={_, Value}}) ->
	Value;
timestamp(via, #fubar{via={_, Value}}) ->
	Value;
timestamp(to, #fubar{to={_, Value}}) ->
	Value;
timestamp(_, #fubar{}) ->
	undefined.

%%
%% Local Functions
%%
ensure_started(App) ->
	prestart(App),
	case application:start(App) of
		ok ->
			ets:insert(?APPLICATION, {App, os:timestamp()}),
			poststart(App);
		{error, {already_started, _}} ->
			poststart(App);
		{error, {not_started, Dep}} ->
			ensure_started(Dep),
			ensure_started(App)
	end.

prestart(cpg) ->
	case application:get_env(?APPLICATION, fubar_master) of
		undefined ->
			ok;
		Master ->
			pong = net_adm:ping(Master)
	end;
prestart(mnesia) ->
	case application:get_env(?APPLICATION, fubar_master) of
		undefined ->
			% schema must be created in standalone mode
			mnesia:create_schema([node()]);
		_Master ->
			% join a cluster and clear stale replica
			case application:get_env(?APPLICATION, fubar_master) of
				undefined ->
					ok;
				Master ->
					pong = net_adm:ping(Master)
			end,
			lists:foreach(fun(N) ->
							  rpc:call(N, mnesia, del_table_copy, [schema, node()])
						  end,
						  nodes())
	end;
prestart(_) ->
	ok.

poststart(mnesia) ->
	case application:get_env(?APPLICATION, fubar_master) of
		undefined ->
			apply_all_module_attributes_of(create_mnesia_tables);
		Master ->
			% create fresh replicas
			{ok, _} = rpc:call(Master, mnesia, change_config, [extra_db_nodes, [node()]]),
			mnesia:change_table_copy_type(schema, node(), disc_copies),
			apply_all_module_attributes_of(merge_mnesia_tables)
	end;
poststart(_) ->
	ok.

ensure_stopped([]) ->
	ok;
ensure_stopped([[App, _] | T]) ->
	prestop(App),
	application:stop(App),
	poststop(App),
	ensure_stopped(T).

prestop(mnesia) ->
	case application:get_env(?APPLICATION, fubar_master) of
		undefined ->
			apply_all_module_attributes_of(destroy_mnesia_tables);
		_Master ->
			apply_all_module_attributes_of(split_mnesia_tables)
	end;
prestop(_) ->
	ok.

poststop(mnesia) ->
	% clear replica before leaving the cluster
	lists:foreach(fun(N) ->
                      case node() of
                          N -> ok;
					      _ -> rpc:call(N, mnesia, del_table_copy, [schema, node()])
                      end
				  end,
				  nodes());
poststop(_) ->
	ok.

apply_all_module_attributes_of({Name, Args}) ->
	[Result || {Module, Attrs} <- all_module_attributes_of(Name),
			   Result <- lists:map(fun(Attr) ->
											case Attr of
				   								{M, F, A} -> {{M, F, A}, apply(M, F, Args++A)};
				   								{F, A} -> {{Module, F, A}, apply(Module, F, Args++A)};
				   								F -> {{Module, F, Args}, apply(Module, F, Args)}
											end
								   end, Attrs)];
apply_all_module_attributes_of(Name) ->
	apply_all_module_attributes_of({Name, []}).

all_module_attributes_of(Name) ->
	Modules = lists:append([M || {App, _, _} <- application:loaded_applications(),
								 {ok, M} <- [application:get_key(App, modules)]]),
	lists:foldl(fun(Module, Acc) ->
						case lists:append([Attr || {N, Attr} <- module_attributes_in(Module),
												   N =:= Name]) of
							[] -> Acc;
							Attr -> [{Module, Attr} | Acc]
						end
				end, [], Modules).

module_attributes_in(Module) ->
	case catch Module:module_info(attributes) of
		{'EXIT', {undef, _}} -> [];
		{'EXIT', Reason} -> exit(Reason);
		Attributes -> Attributes
	end.

apply_config([]) ->
	ok;
apply_config([{App, Params} | T]) ->
	set_env(App, Params),
	apply_config(T).

set_env(_, []) ->
	ok;
set_env(?MODULE, [{Module, Settings} | T]) ->
	settings(Module, Settings),
	set_env(?MODULE, T);
set_env(App, [{Key, Value} | T]) ->
	application:set_env(App, Key, Value),
	set_env(App, T).

stamp({Value, T}, _Now) ->
	{Value, T};
stamp(Value, Now) ->
	{Value, Now}.

replace({Key, Value}, []) ->
	[{Key, Value}];
replace({Key, Value}, [{Key, _} | Rest]) ->
	[{Key, Value} | Rest];
replace({Key, Value}, [NoMatch | Rest]) ->
	[NoMatch | replace({Key, Value}, Rest)].

listener_state([]) ->
	[];
listener_state([{Name, Listener} | Rest]) ->
	case catch supervisor:which_children(Listener) of
		{'EXIT', Reason} ->
			[{Name, {error, Reason}} | listener_state(Rest)];
		Children ->
			[{Name, lists:foldl(fun({ranch_listener, Pid, worker, _}, Acc) ->
										case ranch_listener:get_port(Pid) of
											{ok, Port} ->
												[{port, Port} | Acc];
											Error ->
												[{port, Error} | Acc]
										end;
								   ({ranch_acceptors_sup, Pid, supervisor, _}, Acc) ->
										case catch supervisor:which_children(Pid) of
											{'EXIT', Reason} ->
												[{acceptors, {error, Reason}} | Acc];
											Acceptors ->
												[{acceptors, length(Acceptors)} | Acc]
										end;
								   ({ranch_conns_sup, Pid, supervisor, _}, Acc) ->
										case catch ranch_conns_sup:active_connections(Pid) of
											{'EXIT', Reason} ->
												[{connections, {error, Reason}} | Acc];
											Connections ->
												[{connections, Connections} | Acc]
										end;
								   (_, Acc) ->
										Acc
								end, [], Children)} | listener_state(Rest)]
	end.

wait_for_stop() ->
	Applications = application:which_applications(),
	% ranch could take long time to stop.
	case lists:keyfind(ranch, 1, Applications) of
		false ->
			ok;
		_ ->
			timer:sleep(1000),
			wait_for_stop()
	end.


%%
%% Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
