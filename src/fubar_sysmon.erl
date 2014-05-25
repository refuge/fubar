%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar system monitoring server
%%%
%%% Created : Jan 18, 2014
%%% -------------------------------------------------------------------
-module(fubar_sysmon).
-author("Sungjin Park <jinni.park@gmail.com>").
-behaviour(gen_server).

%%
%% Exports
%%
-export([start_link/0,
         update/0, memory/0, memory/1, load/0, min_load/0,
         high_watermark/0, high_watermark/1,
         interval/0, interval/1,
         offloading_threshold/0, offloading_threshold/1,
         alarm/0,
         apply_setting/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("fubar.hrl").
-include("props_to_record.hrl").

-apply_setting(apply_setting).

-define(SERVER, ?MODULE).

-define(MEMORY_SIZE_FOR_UNKNOWN_OS, 1073741824).

-define(STATE, ?MODULE).

-record(?STATE, {
        group="fubar_sysmon" :: string(),
        high_watermark=0.4 :: number(),
        interval=10000 :: timeout(),
        offloading_threshold=1.2 :: number(),
        timer :: reference(),
        memory_total = ?MEMORY_SIZE_FOR_UNKNOWN_OS :: number(),
        memory_limit = ?MEMORY_SIZE_FOR_UNKNOWN_OS :: number(),
        memory_now = 0 :: number(),
        load = 0 :: number(),
        alarm = none :: none | overloaded | {offloading_to, node()},
        min_load :: {node(), number()}
}).

%% @doc Start gen_server
start_link() ->
    Props = fubar:settings(?MODULE),
    State = ?PROPS_TO_RECORD(Props, ?STATE),
    gen_server:start_link({local, ?SERVER}, ?MODULE, State, []).

%% @doc Force update
update() ->
    gen_server:cast(?SERVER, update).

%% @doc Get memory info
memory() ->
    memory(now).

memory(total) ->
    memory_total(os:type());
memory(vm) ->
    memory_vm(os:type());
memory(limit) ->
    gen_server:call(?SERVER, memory_limit);
memory(now) ->
    gen_server:call(?SERVER, memory_now).

%% @doc Get current load
load() ->
    memory() / memory(limit).

%% @doc Get minimum load
min_load() ->
    gen_server:call(?SERVER, min_load).

%% @doc Get high watermark
high_watermark() ->
    gen_server:call(?SERVER, high_watermark).

%% @doc Set high watermark
high_watermark(Fraction) ->
    gen_server:call(?SERVER, {high_watermark, Fraction}).

%% @doc Get update interval
interval() ->
    gen_server:call(?SERVER, interval).

%% @doc Set update interval
interval(Millisec) ->
    gen_server:call(?SERVER, {interval, Millisec}).

%% @doc Get offloading threshold
offloading_threshold() ->
    gen_server:call(?SERVER, offloading_threshold).

%% @doc Set offloading threshold
offloading_threshold(Fraction) ->
    gen_server:call(?SERVER, {offloading_threshold, Fraction}).

%% @doc Get alarm status
alarm() ->
    gen_server:call(?SERVER, alarm).

apply_setting({high_watermark, Fraction}) ->
    high_watermark(Fraction);
apply_setting({interval, Millisec}) ->
    interval(Millisec);
apply_setting({offloading_threshold, Fraction}) ->
    offloading_threshold(Fraction);
apply_setting(_) ->
    ok.

init(State) ->
    lager:notice("system memory monitor init with ~p", [State]),
    ok = cpg:join(State#?STATE.group),
    Total = memory(total),
    Limit = memory_limit(State#?STATE.high_watermark),
    Timer = start_timer(State#?STATE.interval),
    {ok, internal_update(State#?STATE{
                                memory_total=Total, memory_limit=Limit,
                                timer=Timer, min_load={node(), 0}})}.

handle_call(memory_limit, _From, State) ->
    {reply, State#?STATE.memory_limit, State};
handle_call(memory_now, _From, State) ->
    {reply, State#?STATE.memory_now, State};
handle_call(high_watermark, _From, State) ->
    {reply, State#?STATE.high_watermark, State};
handle_call({high_watermark, Fraction}, _From, State=#?STATE{memory_total=Total}) ->
    Limit = Total * Fraction,
    {reply, ok, State#?STATE{high_watermark=Fraction, memory_limit=Limit}};
handle_call(interval, _From, State) ->
    {reply, State#?STATE.interval, State};
handle_call({interval, Millisec}, _From, State) ->
    {ok, cancel} = timer:cancel(State#?STATE.timer),
    {reply, ok, State#?STATE{interval=Millisec, timer = start_timer(Millisec)}};
handle_call(offloading_threshold, _From, State) ->
    {reply, State#?STATE.offloading_threshold, State};
handle_call({offloading_threshold, Fraction}, _From, State) ->
    {reply, ok, State#?STATE{offloading_threshold=Fraction}};
handle_call(alarm, _From, State) ->
    {reply, State#?STATE.alarm, State};
handle_call(min_load, _From, State) ->
    {reply, State#?STATE.min_load, State};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(update, State) ->
    {noreply, internal_update(State)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({nodedown, N}, State=#?STATE{load=L}) ->
    case State#?STATE.alarm of
        {offloading_to, N} ->
            lager:notice("{offloading_to, ~p} -> none due to nodedown", [N]),
            alarm_handler:clear_alarm({?SERVER, global}),
            {noreply, State#?STATE{alarm=none, min_load={node(), L}}};
        _ ->
            {noreply, State}
    end;
handle_info({N, L}, State=#?STATE{min_load={N0, L0}}) ->
  State1 = case N =:= N0 of
            true ->
              State#?STATE{min_load={N, L}};
            _ ->
              case L < L0 of
                true ->
                  case node() of
                    N0 ->
                      erlang:monitor_node(N, true);
                    N ->
                      erlang:monitor_node(N0, false);
                    _ ->
                      erlang:monitor_node(N0, false),
                      erlang:monitor_node(N, true)
                  end,
                  State#?STATE{min_load={N, L}};
                false ->
                  State
              end
          end,
    {noreply, case node() of
                N -> offload(State1);
                _ -> State1
              end};
handle_info(Info, State) ->
    lager:warning("unknown message ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    lager:notice("system monitor terminate by ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%
%% Local functions
%%
internal_update(State=#?STATE{group=Group, load=L, memory_limit=Mmax}) ->
    M = erlang:memory(total),
    L1 = M/Mmax,
    case {L < 1, L1 < 1} of
        {true, false} ->
            lager:notice("overloaded with ~pMB consumption", [trunc(M/1024/1024)]),
            alarm_handler:set_alarm({{?SERVER, node()}, overloaded});
        {false, true} ->
            lager:notice("not overloaded with ~pMB consumption", [trunc(M/1024/1024)]),
            alarm_handler:clear_alarm({?SERVER, node()});
        _ ->
            ok
    end,
    % Announce my load to the world.
    {ok, Group, Members} = cpg:get_members(Group),
    Message = {node(), M/Mmax},
    lists:foreach(fun(Pid) -> Pid ! Message end, Members),
    State#?STATE{memory_now=M, load=L1}.

offload(State=#?STATE{offloading_threshold=T, load=L}) ->
    case {State#?STATE.alarm, State#?STATE.min_load} of
        {{offloading_to, N}, {_, L0}} when (L < L0*T) or (L0 >= 1) ->
            % It was offloading to some node.
            % L0 is not low enough to continue offloading.
            lager:notice("{offloading_to, ~p} -> none", [N]),
            alarm_handler:clear_alarm({?SERVER, global}),
            State#?STATE{alarm=none};
        {{offloading_to, N}, {N0, _}} when N =/= N0 ->
            % L0 is still low enough and the target node has been changed.
            lager:notice("{offloading_to, ~p} -> {offloading_to, ~p}", [N, N0]),
            Alarm = {offloading_to, N0},
            alarm_handler:set_alarm({{?SERVER, global}, Alarm}),
            State#?STATE{alarm=Alarm};
        {none, {N0, L0}} when (N0 =/= node()) and (L0 < 1) and (L >= L0*T) ->
            % It wasn't offloading but L0 becomes low enough to activate offloading.
            lager:notice("none -> {offloading_to, ~p}", [N0]),
            Alarm = {offloading_to, N0},
            alarm_handler:set_alarm({{?SERVER, global}, Alarm}),
            State#?STATE{alarm=Alarm};
        _ ->
            State
    end.

start_timer(Timeout) ->
    {ok, TRef} = timer:apply_interval(Timeout, ?MODULE, update, []),
    TRef.

%% According to http://msdn.microsoft.com/en-us/library/aa366778(VS.85).aspx
%% Windows has 2GB and 8TB of address space for 32 and 64 bit accordingly.
memory_vm({win32,_OSname}) ->
    case erlang:system_info(wordsize) of
        4 -> 2*1024*1024*1024;          %% 2 GB for 32 bits  2^31
        8 -> 8*1024*1024*1024*1024      %% 8 TB for 64 bits  2^42
    end;

%% On a 32-bit machine, if you're using more than 2 gigs of RAM you're
%% in big trouble anyway.
memory_vm(_OsType) ->
    case erlang:system_info(wordsize) of
        4 -> 4*1024*1024*1024;          %% 4 GB for 32 bits  2^32
        8 -> 256*1024*1024*1024*1024    %% 256 TB for 64 bits 2^48
             %%http://en.wikipedia.org/wiki/X86-64#Virtual_address_space_details
    end.

memory_limit(Fraction) ->
    Memory = lists:min([memory(total), memory(vm)]),
    trunc(Memory * Fraction).

cmd(Command) ->
    Exec = hd(string:tokens(Command, " ")),
    case os:find_executable(Exec) of
        false -> throw({command_not_found, Exec});
        _     -> os:cmd(Command)
    end.

%% get_total_memory(OS) -> Total
%% Windows and Freebsd code based on: memsup:get_memory_usage/1
%% Original code was part of OTP and released under "Erlang Public License".

memory_total({unix,darwin}) ->
    File = cmd("/usr/bin/vm_stat"),
    Lines = string:tokens(File, "\n"),
    Dict = dict:from_list(lists:map(fun parse_line_mach/1, Lines)),
    [PageSize, Inactive, Active, Free, Wired] =
        [dict:fetch(Key, Dict) ||
            Key <- [page_size, 'Pages inactive', 'Pages active', 'Pages free',
                    'Pages wired down']],
    PageSize * (Inactive + Active + Free + Wired);

memory_total({unix,freebsd}) ->
    PageSize  = freebsd_sysctl("vm.stats.vm.v_page_size"),
    PageCount = freebsd_sysctl("vm.stats.vm.v_page_count"),
    PageCount * PageSize;

memory_total({win32,_OSname}) ->
    %% Due to the Erlang print format bug, on Windows boxes the memory
    %% size is broken. For example Windows 7 64 bit with 4Gigs of RAM
    %% we get negative memory size:
    %% > os_mon_sysinfo:get_mem_info().
    %% ["76 -1658880 1016913920 -1 -1021628416 2147352576 2134794240\n"]
    %% Due to this bug, we don't actually know anything. Even if the
    %% number is postive we can't be sure if it's correct. This only
    %% affects us on os_mon versions prior to 2.2.1.
    case application:get_key(os_mon, vsn) of
        undefined ->
            unknown;
        {ok, Version} ->
            case rabbit_misc:version_compare(Version, "2.2.1", lt) of
                true -> %% os_mon is < 2.2.1, so we know nothing
                    unknown;
                false ->
                    [Result|_] = os_mon_sysinfo:get_mem_info(),
                    {ok, [_MemLoad, TotPhys, _AvailPhys,
                          _TotPage, _AvailPage, _TotV, _AvailV], _RestStr} =
                        io_lib:fread("~d~d~d~d~d~d~d", Result),
                    TotPhys
            end
    end;

memory_total({unix, linux}) ->
    File = read_proc_file("/proc/meminfo"),
    Lines = string:tokens(File, "\n"),
    Dict = dict:from_list(lists:map(fun parse_line_linux/1, Lines)),
    dict:fetch('MemTotal', Dict);

memory_total({unix, sunos}) ->
    File = cmd("/usr/sbin/prtconf"),
    Lines = string:tokens(File, "\n"),
    Dict = dict:from_list(lists:map(fun parse_line_sunos/1, Lines)),
    dict:fetch('Memory size', Dict);

memory_total({unix, aix}) ->
    File = cmd("/usr/bin/vmstat -v"),
    Lines = string:tokens(File, "\n"),
    Dict = dict:from_list(lists:map(fun parse_line_aix/1, Lines)),
    dict:fetch('memory pages', Dict) * 4096;

memory_total(_OsType) ->
    ?MEMORY_SIZE_FOR_UNKNOWN_OS.

%% A line looks like "Foo bar: 123456."
parse_line_mach(Line) ->
    [Name, RHS | _Rest] = string:tokens(Line, ":"),
    case Name of
        "Mach Virtual Memory Statistics" ->
            ["(page", "size", "of", PageSize, "bytes)"] =
                string:tokens(RHS, " "),
            {page_size, list_to_integer(PageSize)};
        _ ->
            [Value | _Rest1] = string:tokens(RHS, " ."),
            {list_to_atom(Name), list_to_integer(Value)}
    end.

%% A line looks like "FooBar: 123456 kB"
parse_line_linux(Line) ->
    [Name, RHS | _Rest] = string:tokens(Line, ":"),
    [Value | UnitsRest] = string:tokens(RHS, " "),
    Value1 = case UnitsRest of
                 [] -> list_to_integer(Value); %% no units
                 ["kB"] -> list_to_integer(Value) * 1024
             end,
    {list_to_atom(Name), Value1}.

%% A line looks like "Memory size: 1024 Megabytes"
parse_line_sunos(Line) ->
    case string:tokens(Line, ":") of
        [Name, RHS | _Rest] ->
            [Value1 | UnitsRest] = string:tokens(RHS, " "),
            Value2 = case UnitsRest of
                         ["Gigabytes"] ->
                             list_to_integer(Value1) * 1024 * 1024 * 1024;
                         ["Megabytes"] ->
                             list_to_integer(Value1) * 1024 * 1024;
                         ["Kilobytes"] ->
                             list_to_integer(Value1) * 1024;
                         _ ->
                             Value1 ++ UnitsRest %% no known units
                     end,
            {list_to_atom(Name), Value2};
        [Name] -> {list_to_atom(Name), none}
    end.

%% Lines look like " 12345 memory pages"
%% or              "  80.1 maxpin percentage"
parse_line_aix(Line) ->
    [Value | NameWords] = string:tokens(Line, " "),
    Name = string:join(NameWords, " "),
    {list_to_atom(Name),
     case lists:member($., Value) of
         true  -> trunc(list_to_float(Value));
         false -> list_to_integer(Value)
     end}.

freebsd_sysctl(Def) ->
    list_to_integer(cmd("/sbin/sysctl -n " ++ Def) -- "\n").

%% file:read_file does not work on files in /proc as it seems to get
%% the size of the file first and then read that many bytes. But files
%% in /proc always have length 0, we just have to read until we get
%% eof.
read_proc_file(File) ->
    {ok, IoDevice} = file:open(File, [read, raw]),
    Res = read_proc_file(IoDevice, []),
    file:close(IoDevice),
    lists:flatten(lists:reverse(Res)).

-define(BUFFER_SIZE, 1024).
read_proc_file(IoDevice, Acc) ->
    case file:read(IoDevice, ?BUFFER_SIZE) of
        {ok, Res} -> read_proc_file(IoDevice, [Res | Acc]);
        eof       -> Acc
    end.
