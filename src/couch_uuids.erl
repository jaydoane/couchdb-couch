% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.
-module(couch_uuids).
-include_lib("couch/include/couch_db.hrl").

-behaviour(gen_server).
-vsn(2).
-behaviour(config_listener).

-export([start/0, stop/0]).
-export([new/0, random/0, utc_random/0]).

-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

% config_listener api
-export([handle_config_change/5, handle_config_terminate/3]).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:cast(?MODULE, stop).

new() ->
    gen_server:call(?MODULE, create).

random() ->
    list_to_binary(couch_util:to_hex(crypto:rand_bytes(16))).

utc_random() ->
    utc_suffix(couch_util:to_hex(crypto:rand_bytes(9))).

utc_suffix(Suffix) ->
    Now = {_, _, Micro} = erlang:now(), % uniqueness is used.
    Nowish = calendar:now_to_universal_time(Now),
    Nowsecs = calendar:datetime_to_gregorian_seconds(Nowish),
    Then = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    Prefix = io_lib:format("~14.16.0b", [(Nowsecs - Then) * 1000000 + Micro]),
    list_to_binary(Prefix ++ Suffix).

init([]) ->
    ok = config:listen_for_changes(?MODULE, nil),
    {ok, state()}.

terminate(_Reason, _State) ->
    ok.

handle_call(create, _From, random) ->
    {reply, random(), random};
handle_call(create, _From, utc_random) ->
    {reply, utc_random(), utc_random};
handle_call(create, _From, {utc_id, UtcIdSuffix}) ->
    {reply, utc_suffix(UtcIdSuffix), {utc_id, UtcIdSuffix}};
handle_call(create, _From, {sequential, Pref, Seq}) ->
    Result = ?l2b(Pref ++ io_lib:format("~6.16.0b", [Seq])),
    case Seq >= 16#fff000 of
        true ->
            {reply, Result, {sequential, new_prefix(), inc()}};
        _ ->
            {reply, Result, {sequential, Pref, Seq + inc()}}
    end.

handle_cast(change, _State) ->
    {noreply, state()};
handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_config_change("uuids", _, _, _, _) ->
    {ok, gen_server:cast(?MODULE, change)};
handle_config_change(_, _, _, _, _) ->
    {ok, nil}.

handle_config_terminate(_, stop, _) -> ok;
handle_config_terminate(_, _, _) ->
    spawn(fun() ->
        timer:sleep(5000),
        config:listen_for_changes(?MODULE, undefined),
        % Reload our config in case it changed in the last
        % five seconds.
        gen_server:cast(?MODULE, change)
    end).

new_prefix() ->
    couch_util:to_hex((crypto:rand_bytes(13))).

inc() ->
    crypto:rand_uniform(1, 16#ffe).

state() ->
    AlgoStr = config:get("uuids", "algorithm", "random"),
    case couch_util:to_existing_atom(AlgoStr) of
        random ->
            random;
        utc_random ->
            utc_random;
        utc_id ->
            UtcIdSuffix = config:get("uuids", "utc_id_suffix", ""),
            {utc_id, UtcIdSuffix};
        sequential ->
            {sequential, new_prefix(), inc()};
        Unknown ->
            throw({unknown_uuid_algorithm, Unknown})
    end.
