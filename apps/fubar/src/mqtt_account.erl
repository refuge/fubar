%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : MQTT account module.
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-module(mqtt_account).
-author("Sungjin Park <jinni.park@gmail.com>").

%%
%% Exports
%%
-export([mnesia/1, verify/2, update/2, delete/1]).

%% @doc MQTT account database schema.
-record(?MODULE, {username = '_' :: binary(),
				  password = '_' :: binary()}).

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
verify(Username, Password) ->
	case catch mnesia:dirty_read(?MODULE, Username) of
		[] ->
			{error, not_found};
		[#?MODULE{password=Password}] ->
			ok;
		[#?MODULE{}] ->
			{error, forbidden};
		Error ->
			Error
	end.

%% @doc Update account.
update(Username, Password) ->
	Result = mnesia:dirty_write(#?MODULE{username=Username, password=Password}),
	lager:notice("account ~p update ~p", [Username, Result]),
	Result.

%% @doc Delete account.
delete(Username) ->
	Result = mnesia:dirty_delete(?MODULE, Username),
	lager:notice("account ~p delete ~p", [Username, Result]),
	Result.

%%
%% Unit Tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
