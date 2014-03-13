%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : fubar utility functions. 
%%%
%%% Created : Jan 18, 2014
%%% -------------------------------------------------------------------
-module(fubar_alarm).
-behaviour(gen_event).

-bootstrap_master(boot).
-bootstrap_slave(boot).

-export([boot/0, boot/1, is_alarmed/0, register/1, register/2, on_node_up/1, on_node_down/1]).

-export([init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2, code_change/3]).

-export([remote_conserve_memory/2]). %% Internal use only

-record(alarms, {alertees, alarmed_nodes}).

% jinni, using ets for faster alarm state query
boot() ->
	ets:new(?MODULE, [ordered_set, public, named_table,
					  {write_concurrency, false}, {read_concurrency, true}]).

boot(_) ->
	boot().

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(mfa_tuple() :: {atom(), atom(), list()}).
-spec(start/0 :: () -> 'ok').
-spec(stop/0 :: () -> 'ok').
-spec(register/2 :: (pid(), mfa_tuple()) -> boolean()).
-spec(on_node_up/1 :: (node()) -> 'ok').
-spec(on_node_down/1 :: (node()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------
is_alarmed() ->
	case ets:lookup(?MODULE, vm_memory_monitor) of
		[] -> false;
		_ -> true
	end.

% jinni, a short version of register/2
register(MFA) ->
	?MODULE:register(self(), MFA).

register(Pid, HighMemMFA) ->
    gen_event:call(alarm_handler, ?MODULE,
                   {register, Pid, HighMemMFA},
                   infinity).

on_node_up(Node) -> gen_event:notify(alarm_handler, {node_up, Node}).

on_node_down(Node) -> gen_event:notify(alarm_handler, {node_down, Node}).

%% Can't use alarm_handler:{set,clear}_alarm because that doesn't
%% permit notifying a remote node.
remote_conserve_memory(Pid, true) ->
    gen_event:notify({alarm_handler, node(Pid)},
                     {set_alarm, {{vm_memory_monitor, node()}, []}});
remote_conserve_memory(Pid, false) ->
    gen_event:notify({alarm_handler, node(Pid)},
                     {clear_alarm, {vm_memory_monitor, node()}}).

%%----------------------------------------------------------------------------

init([]) ->
    {ok, #alarms{alertees      = dict:new(),
                 alarmed_nodes = sets:new()}}.

handle_call({register, Pid, HighMemMFA}, State) ->
	fubar_log:debug(?MODULE, [register, Pid]),
    {ok, 0 < sets:size(State#alarms.alarmed_nodes),
     internal_register(Pid, HighMemMFA, State)};

handle_call(_Request, State) ->
    {ok, not_understood, State}.

handle_event({set_alarm, {{vm_memory_monitor, Node}, []}}, State) ->
	ets:insert(?MODULE, {vm_memory_monitor, true}),
    {ok, maybe_alert(fun sets:add_element/2, Node, State)};

handle_event({clear_alarm, {vm_memory_monitor, Node}}, State) ->
	ets:delete(?MODULE, vm_memory_monitor),
    {ok, maybe_alert(fun sets:del_element/2, Node, State)};

handle_event({node_up, Node}, State) ->
    %% Must do this via notify and not call to avoid possible deadlock.
    ok = gen_event:notify(
           {alarm_handler, Node},
           {register, self(), {?MODULE, remote_conserve_memory, []}}),
    {ok, State};

handle_event({node_down, Node}, State) ->
    {ok, maybe_alert(fun sets:del_element/2, Node, State)};

handle_event({register, Pid, HighMemMFA}, State) ->
    {ok, internal_register(Pid, HighMemMFA, State)};

handle_event(_Event, State) ->
    {ok, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason},
            State = #alarms{alertees = Alertees}) ->
	fubar_log:debug(?MODULE, [unregister, Pid]),
    {ok, State#alarms{alertees = dict:erase(Pid, Alertees)}};

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Arg, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%----------------------------------------------------------------------------

maybe_alert(SetFun, Node, State = #alarms{alarmed_nodes = AN,
                                          alertees      = Alertees}) ->
    AN1 = SetFun(Node, AN),
    BeforeSz = sets:size(AN),
    AfterSz  = sets:size(AN1),
    %% If we have changed our alarm state, inform the remotes.
    IsLocal = Node =:= node(),
    if IsLocal andalso BeforeSz < AfterSz -> ok = alert_remote(true,  Alertees);
       IsLocal andalso BeforeSz > AfterSz -> ok = alert_remote(false, Alertees);
       true                               -> ok
    end,
    %% If the overall alarm state has changed, inform the locals.
    case {BeforeSz, AfterSz} of
        {0, 1} -> ok = alert_local(true,  Alertees);
        {1, 0} -> ok = alert_local(false, Alertees);
        {_, _} -> ok
    end,
    State#alarms{alarmed_nodes = AN1}.

alert_local(Alert, Alertees)  -> alert(Alert, Alertees, fun erlang:'=:='/2).

alert_remote(Alert, Alertees) -> alert(Alert, Alertees, fun erlang:'=/='/2).

alert(Alert, Alertees, NodeComparator) ->
    Node = node(),
    dict:fold(fun (Pid, {M, F, A}, ok) ->
                      case NodeComparator(Node, node(Pid)) of
                          true  -> apply(M, F, A ++ [Pid, Alert]);
                          false -> ok
                      end
              end, ok, Alertees).

internal_register(Pid, {M, F, A} = HighMemMFA,
                  State = #alarms{alertees = Alertees}) ->
    _MRef = erlang:monitor(process, Pid),
    case sets:is_element(node(), State#alarms.alarmed_nodes) of
        true  -> ok = apply(M, F, A ++ [Pid, true]);
        false -> ok
    end,
    NewAlertees = dict:store(Pid, HighMemMFA, Alertees),
    State#alarms{alertees = NewAlertees}.
