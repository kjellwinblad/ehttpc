%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(ehttpc_test_lib).

-export([
    nolink_apply/1,
    nolink_apply/2,
    parallel_map/2,
    with_server/2,
    with_server/3,
    with_server/4,
    with_pool/3,
    pool_opts/2,
    pool_opts/3,
    pool_opts/4
]).

-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% @doc Delegate a function to a worker process.
%% The function may spawn_link other processes but we do not
%% want the caller process to be linked.
%% This is done by isolating the possible link with a not-linked
%% middleman process.
nolink_apply(Fun) -> nolink_apply(Fun, infinity).

%% @doc Same as `nolink_apply/1', with a timeout.
-spec nolink_apply(function(), timer:timeout()) -> term().
nolink_apply(Fun, Timeout) when is_function(Fun, 0) ->
    Caller = self(),
    ResRef = make_ref(),
    Middleman = erlang:spawn(
        fun() ->
            process_flag(trap_exit, true),
            CallerMRef = erlang:monitor(process, Caller),
            Worker = erlang:spawn_link(
                fun() ->
                    Res =
                        try
                            {normal, Fun()}
                        catch
                            C:E:S -> {exception, {C, E, S}}
                        end,
                    _ = erlang:send(Caller, {ResRef, Res}),
                    exit(normal)
                end
            ),
            receive
                {'DOWN', CallerMRef, process, _, _} ->
                    %% For whatever reason, if the caller is dead,
                    %% there is no reason to continue
                    exit(Worker, kill),
                    exit(normal);
                {'EXIT', Worker, normal} ->
                    exit(normal);
                {'EXIT', Worker, Reason} ->
                    %% worker has finished its job (Reason=normal)
                    %% or might have crashed due to exception when evaluating Fun
                    _ = erlang:send(Caller, {ResRef, {'EXIT', Reason}}),
                    exit(normal)
            end
        end
    ),
    receive
        {ResRef, {normal, Result}} ->
            Result;
        {ResRef, {exception, {C, E, S}}} ->
            erlang:raise(C, E, S);
        {ResRef, {'EXIT', Reason}} ->
            exit(Reason)
    after Timeout ->
        exit(Middleman, kill),
        exit(timeout)
    end.

%% @doc Like lists:map/2, only the callback function is evaluated
%% concurrently.
-spec parallel_map(function(), list()) -> list().
parallel_map(Fun, List) ->
    nolink_apply(fun() -> do_parallel_map(Fun, List) end).

pool_opts(Port, Pipeline) ->
    pool_opts("127.0.0.1", Port, Pipeline).

pool_opts(Host, Port, Pipeline) ->
    pool_opts(Host, Port, Pipeline, false).

pool_opts(Host, Port, Pipeline, PrioLatest) ->
    [
        {host, Host},
        {port, Port},
        {enable_pipelining, Pipeline},
        {pool_size, 1},
        {pool_type, random},
        {connect_timeout, 5000},
        {prioritise_latest, PrioLatest}
    ].

with_pool(Pool, Opts, F) ->
    application:ensure_all_started(ehttpc),
    try
        {ok, _} = ehttpc_sup:start_pool(Pool, Opts),
        F()
    after
        ehttpc_sup:stop_pool(Pool)
    end.

with_server(Port, Name, Delay, F) ->
    Opts = #{port => Port, name => Name, delay => Delay},
    with_server(Opts, F).

with_server(Opts, F) ->
    with_server(Opts, F, _CheckTrace = fun(_, _) -> ok end).

with_server(Opts, F, CheckTrace) ->
    ?check_trace(
        begin
            Pid = ehttpc_server:start_link(Opts),
            try
                {ok, _} =
                    ?block_until(
                        #{
                            ?snk_kind := ehttpc_server,
                            state := accepting
                        },
                        2_000,
                        infinity
                    ),
                F()
            after
                ehttpc_server:stop(Pid)
            end
        end,
        CheckTrace
    ).

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------

do_parallel_map(Fun, List) ->
    Parent = self(),
    PidList = lists:map(
        fun(Item) ->
            erlang:spawn_link(
                fun() ->
                    Parent ! {self(), Fun(Item)}
                end
            )
        end,
        List
    ),
    lists:foldr(
        fun(Pid, Acc) ->
            receive
                {Pid, Result} ->
                    [Result | Acc]
            end
        end,
        [],
        PidList
    ).
