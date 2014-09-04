-module(fubar_util).

-author("Stephane Wirtel <stephane@wirtel.be>").

-export([
    get_env/1,
    get_env/2
]).

get_env(Key) ->
    get_env(Key, undefined).

get_env(Key, Default) ->
    case application:get_env(fubar, Key) of
        {ok, Value} -> Value;
        _ -> Default
    end.
