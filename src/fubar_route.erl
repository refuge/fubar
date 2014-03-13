%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Routing functions for fubar system.
%%%     This is the core module for fubar's distributed architecture
%%% together with the gateway.
%%%
%%% It governs how the systems work by controlling:
%%%   - how the routing information is stored
%%%   - how the name resolving works
%%%
%%% Created : Nov 16, 2012
%%% -------------------------------------------------------------------
-module(fubar_route).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Exports
%%
-export([mnesia/1, resolve/1, ensure/2, up/2, sync_up/2, down/1, update/2, clean/1]).

-include_lib("stdlib/include/qlc.hrl").

%% @doc Routing table schema
-record(?MODULE, {
		name = '_' :: term(),
		addr = '_' :: undefined | pid(),
		module = '_' :: module(),
		trace = '_' :: boolean()
}).

%% Auto start-up attributes
-create_mnesia_tables({mnesia, [create_tables]}).
-merge_mnesia_tables({mnesia, [merge_tables]}).
-split_mnesia_tables({mnesia, [split_tables]}).

-define(MNESIA_TIMEOUT, 10000).

%% @doc Mnesia table manipulations.
mnesia(create_tables) ->
	mnesia:create_table(?MODULE, [{attributes, record_info(fields, ?MODULE)},
								  {disc_copies, [node()]}, {type, set}]),
	ok = mnesia:wait_for_tables([?MODULE], ?MNESIA_TIMEOUT),
	mnesia(verify_tables);
mnesia(merge_tables) ->
	{atomic, ok} = mnesia:add_table_copy(?MODULE, node(), disc_copies),
	mnesia(verify_tables);
mnesia(split_tables) ->
	mnesia:del_table_copy(?MODULE, node());
mnesia(verify_tables) ->
	Node = node(),
	Q = qlc:q([Route || Route <- mnesia:table(?MODULE),
						Node =:= (catch node(Route#?MODULE.addr))]),
	T = fun() ->
			Routes = qlc:e(Q),
			lists:foreach(
				fun(Route) ->
					mnesia:write(Route#?MODULE{addr=undefined})
				end,
				Routes)
		end,
	mnesia:async_dirty(T).

%% @doc Resovle given name into address.
resolve(Name) ->
	F = fun() ->
			case mnesia:wread({?MODULE, Name}) of
				[#?MODULE{name=Name, addr=undefined, module=Module, trace=Trace}] ->
					{ok, {undefined, Module, Trace}};
				[#?MODULE{name=Name, addr=Addr, module=Module, trace=Trace}] ->
					case check_process(Addr) of
						true ->
							{ok, {Addr, Module, Trace}};
						_ ->
							{ok, {undefined, Module, Trace}}
					end;
				[] ->
					{error, not_found};
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:async_dirty(F) of
		{'EXIT', Reason} -> {error, Reason};
		Result -> Result
	end.

%% @doc Ensure given name exists.
ensure(Name, Module) ->
	F = fun() ->
			case mnesia:read(?MODULE, Name) of
				[#?MODULE{name=Name, addr=Addr, module=Module, trace=Trace}] ->
					case check_process(Addr) of
						true ->
							{ok, {Addr, Module, Trace}};
						_ ->
							case Module:start([{name, Name}, {trace, Trace}]) of
								{ok, Pid} -> {ok, {Pid, Module, Trace}};
								Error -> Error
							end
					end;
				[#?MODULE{name=Name}] ->
					{error, collision};
				[] ->
					case Module:start([{name, Name}]) of
						{ok, Pid} -> {ok, {Pid, Module, false}};
						Error -> Error
					end;
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:async_dirty(F) of
		{'EXIT', Reason} -> {error, Reason};
		Result -> Result
	end.

%% @doc Update route with fresh name and address.
up(Name, Module) ->
	Pid = self(),
	Route = #?MODULE{name=Name, addr=Pid, module=Module, trace=false},
	F = fun() ->
			case mnesia:wread({?MODULE, Name}) of
				[#?MODULE{name=Name, addr=Pid, module=Module}] ->
					% Ignore duplicate up call.
					ok;
				[#?MODULE{name=Name, addr=undefined, module=Module}] ->
					mnesia:write(Route);
				[#?MODULE{name=Name, addr=Addr, module=Module}] ->
					% Oust old one.
					Addr ! {stop, self()},
					mnesia:write(Route);
				[#?MODULE{name=Name}] ->
					% Occupied by different module.
					{error, collision};
				[] ->
					mnesia:write(Route);
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:async_dirty(F) of
		{'EXIT', Reason} -> {error, Reason};
		Result -> Result
	end.

%% @doc Synchronously update route with fresh name and address.
sync_up(Name, Module) ->
	Pid = self(),
	Route = #?MODULE{name=Name, addr=Pid, module=Module, trace=false},
	F = fun() ->
			case mnesia:wread({?MODULE, Name}) of
				[#?MODULE{name=Name, addr=undefined, module=Module}] ->
					mnesia:write(Route);
				[#?MODULE{name=Name, addr=_, module=Module}] ->
					% Can't ignore duplicate up
					{error, already_exists};
				[#?MODULE{name=Name}] ->
					% Occupied by different module.
					{error, collision};
				[] ->
					mnesia:write(Route);
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:transaction(F) of
		{atomic, Result} -> Result;
		{'EXIT', Reason} -> {error, Reason};
		Error -> Error
	end.

%% @doc Update route with stale name and address.
down(Name) ->
	Self = self(),
	F = fun() ->
			case mnesia:wread({?MODULE, Name}) of
				[Route=#?MODULE{addr=Self}] ->
					mnesia:write(Route#?MODULE{addr=undefined});
				[_] ->
					{error, not_allowed};
				[] ->
					{error, not_found};
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:async_dirty(F) of
		{'EXIT', Reason} -> {error, Reason};
		Result -> Result
	end.

%% @doc Update route info.
update(Name, {trace, Trace}) ->
	F = fun() ->
			case mnesia:wread({?MODULE, Name}) of
				[Route=#?MODULE{name=Name}] ->
					mnesia:write(Route#?MODULE{trace=Trace});
				[] ->
					{error, not_found};
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:async_dirty(F) of
		{'EXIT', Reason} -> {error, Reason};
		Result -> Result
	end.

%% @doc Delete route.
clean(Name) ->
	Self = self(),
	F = fun() ->
			case mnesia:wread({?MODULE, Name}) of
				[#?MODULE{addr=Self}] ->
					mnesia:delete({?MODULE, Name});
				[_] ->
					{error, not_allowed};
				[] ->
					{error, not_found};
				Error ->
					{error, Error}
			end
		end,
	case catch mnesia:async_dirty(F) of
		{'EXIT', Reason} -> {error, Reason};
		Result -> Result
	end.

%%
%% Local
%%		
check_process(undefined) ->
	false;
check_process(Pid) ->
	Local = node(),
	case node(Pid) of
		Local -> % local process
			is_process_alive(Pid);
		Remote -> % remote process
			rpc:call(Remote, erlang, is_process_alive, [Pid])
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

check_process_test() ->
	?assert(check_process(self()) == true).

-endif.
