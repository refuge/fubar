%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar command line control functions. 
%%%
%%% Created : Jan 14, 2013
%%% -------------------------------------------------------------------
-module(fubar_control).

%% ====================================================================
%% API functions
%% ====================================================================
-export([call/1]).

call([Node, state]) ->
	case catch rpc:call(Node, fubar, state, []) of
		{ok, State} ->
			io:format("~n== ~p running ==~n", [Node]),
			pretty_print(State);
		Error ->
			io:format("~n== ~p error ==~n~p~n~n", [Node, Error])
	end,
	halt();
call([Node, stop]) ->
	io:format("~n== ~p stopping ==~n", [Node]),
	io:format("~p~n~n", [catch rpc:call(Node, fubar, stop, [])]),
	halt();
call([Node, acl, all]) ->
	io:format("~n== ~p acl all ==~n", [Node]),
	io:format("~p~n~n", [catch rpc:call(Node, mnesia, dirty_all_keys, [mqtt_acl])]),
	halt();
call([Node, acl, get, IP]) ->
	io:format("~n== ~p acl get ~s ==~n", [Node, IP]),
	[S1, S2, S3, S4] = string:tokens(atom_to_list(IP), "."),
	{I1, _} = string:to_integer(S1),
	{I2, _} = string:to_integer(S2),
	{I3, _} = string:to_integer(S3),
	{I4, _} = string:to_integer(S4),
	io:format("~p~n~n", [catch rpc:call(Node, mnesia, dirty_read, [mqtt_acl, {I1,I2,I3,I4}])]),
	halt();
call([Node, acl, set, IP, Allow]) ->
	io:format("~n== ~p acl set ~s ~s ==~n", [Node, IP, Allow]),
	[S1, S2, S3, S4] = string:tokens(atom_to_list(IP), "."),
	{I1, _} = string:to_integer(S1),
	{I2, _} = string:to_integer(S2),
	{I3, _} = string:to_integer(S3),
	{I4, _} = string:to_integer(S4),
	io:format("~p~n~n", [catch rpc:call(Node, mqtt_acl, update, [{I1,I2,I3,I4}, Allow])]),
	halt();
call([Node, acl, del, IP]) ->
	io:format("~n== ~p acl del ~s ==~n", [Node, IP]),
	[S1, S2, S3, S4] = string:tokens(atom_to_list(IP), "."),
	{I1, _} = string:to_integer(S1),
	{I2, _} = string:to_integer(S2),
	{I3, _} = string:to_integer(S3),
	{I4, _} = string:to_integer(S4),
	io:format("~p~n~n", [catch rpc:call(Node, mqtt_acl, delete, [{I1,I2,I3,I4}])]),
	halt();
call([Node, account, all]) ->
	io:format("~n== ~p account all ==~n", [Node]),
	io:format("~p~n~n", [catch rpc:call(Node, mnesia, dirty_all_keys, [mqtt_account])]),
	halt();
call([Node, account, get, Username]) ->
	io:format("~n== ~p account get ~s ==~n", [Node, Username]),
	io:format("~p~n~n", [catch rpc:call(Node, mnesia, dirty_read,
										[mqtt_account, atom_to_binary(Username, utf8)])]),
	halt();
call([Node, account, set, Username, Password]) ->
	io:format("~n== ~p account set ~s ~s ==~n", [Node, Username, Password]),
	io:format("~p~n~n", [catch rpc:call(Node, mqtt_account, update,
										[atom_to_binary(Username, utf8), atom_to_binary(Password, utf8)])]),
	halt();
call([Node, account, del, Username]) ->
	io:format("~n== ~p account del ~s ==~n", [Node, Username]),
	io:format("~p~n~n", [catch rpc:call(Node, mqtt_account, delete, [atom_to_binary(Username, utf8)])]),
	halt();
call([Node, trace, Name, Value]) ->
	io:format("~n== ~p trace ~p ~p == ~n", [Node, Name, Value]),
	io:format("~p~n~n", [catch rpc:call(Node, mqtt_session, trace, [atom_to_binary(Name, utf8), Value])]),
	halt();
call(_) ->
	io:format(standard_error, "Available commands: run, stop, state, acl-all, acl-get, acl-set, acl-del", []),
	halt().

%% ====================================================================
%% Internal functions
%% ====================================================================
pretty_print([]) ->
	io:format("~n");
pretty_print([{Key, Value} | More]) ->
	io:format("~12s : ~p~n", [Key, Value]),
	pretty_print(More).