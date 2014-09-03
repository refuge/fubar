%%% -------------------------------------------------------------------
%%% Author  : Sungjin Park <jinni.park@gmail.com>
%%%
%%% Description : Some log macros.
%%%   ?DEBUG(Exp) -> evaluates Exp, prints a debug message after the evaluation
%%%					if 'DEBUG' is defined at compile time.
%%%   ?TRACE(Exp) -> evaluates Exp, prints a debug message before and after the
%%%					evaluation if 'DEBUG' is defined at compile time.
%%%   ?INFO(Message) -> print an info message
%%%   ?WARNING(Message) -> print a warning message
%%%   ?ERROR(Message) -> print an error message
%%%
%%% Created : Feb 26, 2012
%%% -------------------------------------------------------------------
-author("Sungjin Park <jinni.park@gmail.com>").

-ifdef(DEBUG).

%% @doc Print a debug message if 'DEBUG' is defined at compile time.
-define(DEBUG(Report), error_logger:info_msg("~s: ~p~n[DEBUG ~p] ~p~n", [?MODULE, ?LINE, self(), Report])).

%% @doc Evaluate Exp, print a debug message before and after the evaluation if
%% 'DEBUG' is defined at compile time.
-define(TRACE(Exp), ?TRACE_FUN(Exp)(error_logger:info_msg("~s: ~p~n[TRACE ~p] ~p~n", [?MODULE, ?LINE, self(), ??Exp]))).
-define(TRACE_FUN(Exp),
		fun(_Init) -> % Init is here just as a placeholder, guarantees to be evaluated before this is called.
				Var = Exp, % It's essential to bind to a Var here to avoid evaluating Exp twice.
				error_logger:info_msg("~s: ~p~n[TRACE ~p] ~p~n", [?MODULE, ?LINE, self(), Var]),
				Var
		end).

-else.

-define(DEBUG(Report), ok).
-define(TRACE(Exp), Exp).

-endif.

%% @doc Print an info message.
-define(INFO(Report), error_logger:info_report([{?MODULE, self()}, Report])).

%% @doc Print a warning message.  Need to run the shell with '+W w' option.
-define(WARNING(Report), error_logger:warning_report([{?MODULE, self()}, Report])).

%% @doc Print an error message.
-define(ERROR(Report), error_logger:error_report([{?MODULE, self()}, Report])).
