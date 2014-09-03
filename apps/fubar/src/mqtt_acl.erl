%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT access control list module.
%%%
%%% Created : Dec 10, 2012
%%% -------------------------------------------------------------------
-module(mqtt_acl).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Exports
%%
-export([mnesia/1, verify/1, update/2, delete/1]).

%% @doc MQTT acl database schema.
-record(?MODULE, {addr = '_' :: binary(),
				  allow = '_' :: binary()}).

%% Auto start-up attributes
-create_mnesia_tables({mnesia, [create_tables]}).
-merge_mnesia_tables({mnesia, [merge_tables]}).
-split_mnesia_tables({mnesia, [split_tables]}).

-define(MNESIA_TIMEOUT, 10000).

%% @doc Mnesia table manipulations.
mnesia(create_tables) ->
	mnesia:create_table(?MODULE, [{attributes, record_info(fields, ?MODULE)},
								  {disc_copies, [node()]}, {type, set}]),
	ok = mnesia:wait_for_tables([?MODULE], ?MNESIA_TIMEOUT);
mnesia(merge_tables) ->
	{atomic, ok} = mnesia:add_table_copy(?MODULE, node(), disc_copies);
mnesia(split_tables) ->
	mnesia:del_table_copy(?MODULE, node()).

%% @doc Verify credential.
verify(Addr) ->
	case catch mnesia:dirty_read(?MODULE, Addr) of
		[] ->
			{error, not_found};
		[#?MODULE{allow=true}] ->
			ok;
		[#?MODULE{}] ->
			{error, forbidden};
		Error ->
			Error
	end.

%% @doc Update account.
update(Addr, Allow) ->
	Result = mnesia:dirty_write(#?MODULE{addr=Addr, allow=Allow}),
	lager:notice("acl {~p,~p} update ~p", [Addr, Allow, Result]),
	Result.

%% @doc Delete account.
delete(Addr) ->
	Result = mnesia:dirty_delete(?MODULE, Addr),
	lager:notice("acl ~p delete ~p", [Addr, Result]),
	Result.

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
