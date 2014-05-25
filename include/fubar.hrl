%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar internal message type. 
%%%
%%% Created : Nov 14, 2012
%%% -------------------------------------------------------------------
-type hostname() :: string().
-type ipaddr() :: ipv4addr() | ipv6addr().
-type ipv4addr() :: {byte(),byte(),byte(),byte()}.
-type ipv6addr() :: {word(),word(),word(),word(),word(),word(),word(),word()}.
-type ipport() :: word().
-type nwaddr() :: {hostname(),ipport()} | {ipaddr(),ipport()}.
-type socket() :: port().
-type param() :: {atom(), term()}.
-type proplist(Key, Value) :: [{Key, Value} | Key].
-type params() :: proplist(atom(), term()).
-type reason() :: term().
-type word() :: 0..65535.
-type timestamp() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}.

-record(fubar, {id :: term(),
				from :: term() | {term(), timestamp()},
				via :: term() | {term(), timestamp()},
				to :: term() | {term(), timestamp()},
				payload :: term()}).

-type fubar() :: #fubar{}.
