%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Fubar log manager.
%%%
%%% Created : Nov 30, 2012
%%% -------------------------------------------------------------------
-module(fubar_log).
-author("Sungjin Park <jinni.park@gmail.com>").
-behavior(gen_server).

%%
%% Exports
%%
-export([start_link/0,		% Start log manager
		 access/2, packet/2, protocol/2, resource/2,
		 debug/2, info/2, warning/2, error/2, trace/2,	% Per class logging
		 log/3,				% Generic logging
		 dump/0, dump/2,	% Dump logs to text
		 open/1, close/1,	% Open/close logs
		 out/1, out/2,		% Control log output
		 interval/1,		% Control log output interval
		 state/0			% Check log manager state
		]).

%%
%% Includes
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("fubar.hrl").
-include("sasl_log.hrl").
-include("props_to_record.hrl").

%%
%% Macros, records and types
%%
-record(?MODULE, {dir = "priv/log" :: string(),
				  max_bytes = 1048576 :: integer(),
				  max_files = 10 :: integer(),
				  distributed = true :: boolean(),
				  classes = [] :: [{atom(), term(),
									none | standard_io | pid() |
										{string(), string(), string(), integer(), integer(), pid()}}],
				  interval = 100 :: timeout()}).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% @doc Start a log manager.
%%      The log manager process manages disk_logs and polls them to redirect output.
-spec start_link() -> {ok, pid()} | {error, reason()}.
start_link() ->
	State = ?PROPS_TO_RECORD(fubar:settings(?MODULE), ?MODULE),
	[Name | _] = string:tokens(lists:flatten(io_lib:format("~s", [node()])), "@"),
	Path = filename:join(State#?MODULE.dir, Name),
	ok = filelib:ensure_dir(Path++"/"),
	gen_server:start_link({local, ?MODULE}, ?MODULE, State#?MODULE{dir=Path}, []).

%% @doc Access log records client connect/disconnect events.
-spec access(module(), term()) -> ok | {error, reason()}.
access(Tag, Term) ->
	log(access, Tag, Term).

%% @doc Packet log records binary packets to/from clients.
-spec packet(module(), term()) -> ok | {error, reason()}.
packet(Tag, Term) ->
	log(packet, Tag, Term).

%% @doc Protocol log records messages.
-spec protocol(module(), term()) -> ok | {error, reason()}.
protocol(Tag, Term) ->
	log(protocol, Tag, Term).

%% @doc Resource log records session/topic create/destroy events.
-spec resource(module(), term()) -> ok | {error, reason()}.
resource(Tag, Term) ->
	log(resource, Tag, Term).

%% @doc Debug log records various debugging checkpoints.
-spec debug(module(), term()) -> ok | {error, reason()}.
debug(Tag, Term) ->
	log(debug, Tag, Term).

%% @doc Info log records normal events.
-spec info(module(), term()) -> ok | {error, reason()}.
info(Tag, Term) ->
	log(info, Tag, Term).

%% @doc Warning log records abnormal but not critical events.
-spec warning(module(), term()) -> ok | {error, reason()}.
warning(Tag, Term) ->
	log(warning, Tag, Term).

%% @doc Error log records abnormal and critical events.
-spec error(module(), term()) -> ok | {error, reason()}.
error(Tag, Term) ->
	log(error, Tag, Term).

%% @doc Trace log records a message with routing info and timing.
-spec trace(term(), #fubar{}) -> ok.
trace(_, #fubar{id=undefined}) ->
	ok;
trace(Tag, #fubar{id=Id, origin={Origin, T1}, from={From, T2}, via={Via, T3}, payload=Payload}) ->
	Now = now(),
	log(trace, Tag, [{fubar, Id}, {since, {Origin, timer:now_diff(Now, T1)/1000},
										  {From, timer:now_diff(Now, T2)/1000},
										  {Via, timer:now_diff(Now, T3)/1000}},
					 {payload, Payload}]).

%% @doc Generic logging.
-spec log(atom(), term(), term()) -> ok | {error, reason()}.
log(Class, Tag, Term) ->
	{{Y, M, D}, {H, Min, S}} = calendar:universal_time(),
	Date = lists:flatten(io_lib:format("~4..0B-~2..0B-~2..0B", [Y, M, D])),
	Time = lists:flatten(io_lib:format("~2..0B:~2..0B:~2..0B", [H, Min, S])),
	catch disk_log:log(Class, [Date, Time, node(), self(), Tag, Term]).

%% @doc Dump all log classes to text files.
dump() ->
	case state() of
		#?MODULE{dir=Dir, classes=Classes} ->
			[Name | _] = string:tokens(lists:flatten(io_lib:format("~s", [node()])), "@"),
			{{Y, M, D}, {H, Min, S}} = calendar:universal_time(),
			Base = io_lib:format("~s-~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0B-",
								 [Name, Y, M, D, H, Min, S]),
			lists:map(fun({Class, _, _}) ->
							  Filename = io_lib:format("~s~s.log", [Base, Class]),
							  {Class, catch dump(Dir, Class, lists:flatten(Filename))}
					  end, Classes);
		Error ->
			Error
	end.

%% @doc Dump a log class to a text file.
dump(Class, Filename) ->
	case state() of
		#?MODULE{dir=Dir} ->
			dump(Dir, Class, Filename);
		Error ->
			Error
	end.

%% @doc Open a log class.
-spec open(atom() | [atom()]) -> ok | {error, reason()}.
open(Classes) when is_list(Classes) ->
	lists:foreach(fun ?MODULE:open/1, Classes);
open(Class) ->
	gen_server:call(?MODULE, {open, Class}).

%% @doc Close a log class.
-spec close(atom()| [atom()]) -> ok.
close(Classes) when is_list(Classes) ->
	lists:foreach(fun ?MODULE:close/1, Classes);
close(Class) ->
	gen_server:call(?MODULE, {close, Class}).

%% @doc Redirect all open logs.
-spec out(none | standard_io | pid() | string()) -> ok.
out(Io) ->
	gen_server:call(?MODULE, {out, Io}).

%% @doc Redirect an open log.
-spec out(atom(), none | standard_io | pid() | string()) -> ok.
out(Class, Io) ->
	gen_server:call(?MODULE, {out, Class, Io}).

%% @doc Set log redirect interval.
-spec interval(timeout()) -> ok.
interval(T) ->
	gen_server:call(?MODULE, {interval, T}).

%% @doc Get the log manager state.
-spec state() -> #?MODULE{}.
state() ->
	gen_server:call(?MODULE, state).

%%
%% Callback Functions
%%
init(State=#?MODULE{dir=Dir, max_bytes=L, max_files=N, distributed=Distributed,
					classes=List, interval=T}) ->
	?INFO(["log manager started", State]),
	% Open all the log classes first and close some of them.
	All = lists:foldl(fun(Class, Acc) ->
							  case open(Class, Dir, L, N, Distributed) of
								  {ok, {Class, Current}} ->
									  ?INFO(["disk_log open", Class]),
									  Acc++[{Class, Current}];
								  Error ->
									  ?ERROR(["can't open disk_log", Class, Error]),
									  Acc
							  end
					  end, [], [access, packet, protocol, resource, debug, info, warning, error, trace]),
	Classes = lists:foldl(fun({Class, Current}, Acc) ->
								  case lists:keyfind(Class, 1, List) of
									  {Class, Out} when is_list(Out) ->
										  Acc++[{Class, Current, {Dir, Out, undefined, 0, L, undefined}}];
									  {Class, Out} ->
										  Acc++[{Class, Current, Out}];
									  false ->
										  disk_log:close(Class),
										  ?INFO(["disk_log closed", Class]),
										  Acc
								  end
						  end, [], All),
	{ok, State#?MODULE{classes=Classes}, T}.

handle_call({open, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case open(Class, State#?MODULE.dir, State#?MODULE.max_bytes, State#?MODULE.max_files,
			  State#?MODULE.distributed) of
		{ok, {Class, Current}} ->
			?INFO(["disk_log open", Class]),
			{reply, ok, State#?MODULE{classes=[{Class, Current, none} | Classes]}, T};
		Error ->
			?ERROR(["can't open disk_log", Class]),
			{reply, Error, State, T}
	end;
handle_call({close, Class}, _, State=#?MODULE{classes=Classes, interval=T}) ->
	case lists:keytake(Class, 1, Classes) of
		{value, {Class, _, _}, Rest} ->
			case disk_log:close(Class) of
				ok ->
					?INFO(["disk_log closed", Class]),
					{reply, ok, State#?MODULE{classes=Rest}, T};
				Error ->
					?ERROR(["can't close disk_log", Class]),
					{reply, Error, State, T}
			end;
		false ->
			{reply, {error, not_found}, State, T}
	end;
handle_call({out, Io}, _, State=#?MODULE{dir=Dir, max_bytes=L, classes=OldClasses, interval=T}) ->
	Classes = case Io of
				  String when is_list(String) ->
					  [{Class, Current, {Dir, String, undefined, 0, L, undefined}} || {Class, Current, _} <- OldClasses];
				  _ ->
					  [{Class, Current, Io} || {Class, Current, _} <- OldClasses]
			  end,
	{reply, ok, State#?MODULE{classes=Classes}, T};
handle_call({out, Class, Io}, _, State=#?MODULE{dir=Dir, max_bytes=L, classes=OldClasses, interval=T}) ->
	case lists:keytake(Class, 1, OldClasses) of
		{value, {Class, Current, OldIo}, Rest} ->
			case OldIo of
				{_, _, File} ->
					catch file:close(File);
				_ ->
					ok
			end,
			Classes = case Io of
						  String when is_list(String) ->
							  [{Class, Current, {Dir, String, undefined, 0, L, undefined}} | Rest];
						  _ ->
							  [{Class, Current, Io} | Rest]
					  end,
			{reply, ok, State#?MODULE{classes=Classes}, T};
		false ->
			{reply, {error, not_found}, State, T}
	end;
handle_call({interval, T}, _, State=#?MODULE{interval=_}) ->
	{reply, ok, State#?MODULE{interval=T}, T};
handle_call(state, _, State=#?MODULE{interval=T}) ->
	{reply, State, State, T};
handle_call(Request, From, State) ->
	debug(?MODULE, ["unknwon call", Request, From]),
	{reply, {error, unknown}, State}.

handle_cast(Message, State) ->
	debug(?MODULE, ["unknown cast", Message]),
	{noreply, State}.

handle_info(timeout, State) ->
	F = fun({Class, Last, Io}, Acc) ->
			case consume_log(Class, Last, Io) of
				{ok, Current, NewIo} ->
					Acc ++ [{Class, Current, NewIo}];
				Error ->
					?ERROR(["can't consume disk_log", Class, Error]),
					Acc
			end
		end,
	Classes = lists:foldl(F, [], State#?MODULE.classes),
	{noreply, State#?MODULE{classes=Classes}, State#?MODULE.interval};
handle_info(Info, State) ->
	debug(?MODULE, ["unknown info", Info]),
	{noreply, State}.

terminate(Reason, State) ->
	Close = fun({Class, _, _}) ->
				disk_log:close(Class)
			end,
	lists:foreach(Close, State#?MODULE.classes),
	Reason.

code_change(OldVsn, State, Extra) ->
	?WARNING([code_change, OldVsn, State, Extra]),
	{ok, State}.

%%
%% Local Functions
%%
open(Class, Dir, L, N, Distributed) ->
   File = filename:join(Dir, io_lib:format("~s", [Class])),
   Size = case filelib:last_modified(File) of
			  0 ->
				  {L, N};
			  _ ->
				  ?INFO(["disk_log already exists, applying previous size"]),
				  infinity
		  end,
   Opt = case Distributed of
			 true -> [{distributed, [node()]}];
			 _ -> []
		 end,
   case disk_log:open([{name, Class}, {file, File}, {type, wrap},
					   {repair, truncate}, {size, Size} | Opt]) of
	   {error, Reason} ->
		   {error, Reason};
	   _ ->
		   {ok, Current, _} = consume_log(Class, start, none),
		   {ok, {Class, Current}}
   end.

consume_log(Log, Last, Io) ->
	case disk_log:chunk(Log, Last) of
		{error, Reason} ->
			{error, Reason};
		eof ->
			{ok, Last, Io};
		{Current, Terms} ->
			case Io of
				none ->
					{ok, Last, Io};
				Redir = {_, _, _, _, _, _} -> % redirect to dayfile
					NewIo = update_datelog(Redir, Log, Terms),
					consume_log(Log, Current, NewIo);
				_ ->
					lists:foreach(fun(Term) -> print_log(Io, Log, Term) end, Terms),
					consume_log(Log, Current, Io)
			end
	end.

update_datelog(Io, _, []) ->
	Io;
update_datelog({Dir, Prefix, _, N, M, undefined}, Log, Term=[[Suffix | _] | _]) ->
	% This is the first datelog attempt.
	Basename = filename:join(Dir, Prefix)++"_"++Suffix++".log",
	Filename = io_lib:format("~s.~B", [Basename, N+1]),
	{ok, File} = file:open(Filename, [append]),
	update_datelog({Dir, Prefix, Suffix, N+1, M, File}, Log, Term);
update_datelog({Dir, Prefix, Suffix, N, M, File}, Log, [[Suffix | Term] | Rest]) ->
	case catch file:position(File, {cur, 0}) of
		{ok, L} when L < M ->
			print_log(File, Log, [Suffix | Term]),
			update_datelog({Dir, Prefix, Suffix, N, M, File}, Log, Rest);
		_ ->
			catch file:close(File),
			update_datelog({Dir, Prefix, Suffix, N, M, undefined}, Log, [[Suffix | Term] | Rest])
	end;
update_datelog({Dir, Prefix, _, _, M, File}, Log, Term=[[Suffix | _] | _]) ->
	% New suffix, start another datelogging.
	catch file:close(File),
	update_datelog({Dir, Prefix, Suffix, 0, M, undefined}, Log, Term);
update_datelog(Io, Log, [_ | Rest]) ->
	update_datelog(Io, Log, Rest).

print_log(Io, Log, [Date, Time, Node, Pid, Tag, Term]) ->
	io:format(Io, "~-8.8s ~s ~s ~p ~p ~p ~1000p~n", [Log, Date, Time, Node, Pid, Tag, Term]);
print_log(Io, Log, Term) ->
	io_lib:format(Io, "~-8.8s ~1000p~n", [Log, Term]).

dump(Dir, Class, Filename) ->
	Path = filename:join(Dir, io_lib:format("~s", [Class])),
	case disk_log:open([{name, Class}, {file, Path}, {type, wrap}]) of
		{error, Reason} ->
			{error, Reason};
		_ ->
			case file:open(Filename, [write]) of
				{ok, File} ->
					consume_log(Class, start, File),
					file:close(File);
				Error1 ->
					Error1
			end,
			disk_log:close(Class)
	end.

%%
%% Unit Tests
%%
-ifdef(TEST).
-endif.