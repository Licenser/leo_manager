%%======================================================================
%%
%% Leo Manager
%%
%% Copyright (c) 2012 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% LeoFS Manager - CUI Console
%% @doc
%% @end
%%======================================================================
-module(leo_manager_console_cui).

-author('Yosuke Hara').

-include("leo_manager.hrl").
-include_lib("leo_commons/include/leo_commons.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1, stop/0]).
-export([init/1, handle_call/3]).


%%----------------------------------------------------------------------
%%
%%----------------------------------------------------------------------
start_link(Params) ->
    tcp_server:start_link(?MODULE, [], Params).

stop() ->
    tcp_server:stop().

%%----------------------------------------------------------------------
%% Callback function(s)
%%----------------------------------------------------------------------
init(_Args) ->
    {ok, []}.


%%----------------------------------------------------------------------
%% Operation-1
%%----------------------------------------------------------------------
handle_call(_Socket, <<?HELP>>, State) ->
    Commands = lists:append([io_lib:format("[Cluster]\r\n", []),
                             io_lib:format("~s\r\n",["detach ${NODE}"]),
                             io_lib:format("~s\r\n",["suspend ${NODE}"]),
                             io_lib:format("~s\r\n",["resume ${NODE}"]),
                             io_lib:format("~s\r\n",["start"]),
                             io_lib:format("~s\r\n",["rebalance"]),
                             io_lib:format("~s\r\n",["whereis ${PATH}"]),
                             ?CRLF,
                             io_lib:format("[Storage]\r\n", []),
                             io_lib:format("~s\r\n",["du ${NODE}"]),
                             io_lib:format("~s\r\n",["compact ${NODE}"]),
                             ?CRLF,
                             io_lib:format("[Gateway]\r\n", []),
                             io_lib:format("~s\r\n",["purge ${PATH}"]),
                             ?CRLF,
                             io_lib:format("[S3]\r\n", []),
                             io_lib:format("~s\r\n",["s3-gen-key ${USER-ID}"]),
                             io_lib:format("~s\r\n",["s3-set-endpoint ${ENDPOINT}"]),
                             io_lib:format("~s\r\n",["s3-delete-endpoint ${ENDPOINT}"]),
                             io_lib:format("~s\r\n",["s3-get-endpoints"]),
                             io_lib:format("~s\r\n",["s3-get-buckets"]),
                             ?CRLF,
                             io_lib:format("[Misc]\r\n", []),
                             io_lib:format("~s\r\n",["version"]),
                             io_lib:format("~s\r\n",["status"]),
                             io_lib:format("~s\r\n",["history"]),
                             io_lib:format("~s\r\n",["quit"]),
                             ?CRLF]),
    {reply, Commands, State};


%% Command: "version"
%%
handle_call(_Socket, <<?VERSION, _/binary>>, State) ->
    {ok, Reply} = leo_manager_console_commons:version(),
    {reply, lists:append([Reply, ?CRLF, ?CRLF]), State};


%% Command: "status"
%% Command: "status ${NODE_NAME}"
%%
handle_call(_Socket, <<?STATUS, Option/binary>> = Command, State) ->
    Reply = case leo_manager_console_commons:status(Command, Option) of
                {ok, {node_list, Props}} ->
                    format_node_list(Props);
                {ok, NodeStatus} ->
                    format_node_state(NodeStatus);
                {error, Cause} ->
                    io_lib:format("[ERROR] ~s\r\n", [Cause])
            end,
    {reply, Reply, State};


%% Command : "detach ${NODE_NAME}"
%%
handle_call(_Socket, <<?DETACH_SERVER, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),
    {ok, SystemConf} = leo_manager_mnesia:get_system_config(),

    Reply =
        case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
            [] ->
                io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_NODE_SPECIFIED]);
            [Node|_] ->
                NodeAtom = list_to_atom(Node),

                case leo_manager_mnesia:get_storage_node_by_name(NodeAtom) of
                    {ok, [#node_state{state = ?STATE_ATTACHED} = NodeState|_]} ->
                        ok = leo_manager_mnesia:delete_storage_node(NodeState),
                        ok = leo_manager_cluster_monitor:demonitor(NodeAtom),
                        ?OK;
                    _ ->
                        case leo_manager_mnesia:get_storage_nodes_by_status(?STATE_RUNNING) of
                            {ok, Nodes} when length(Nodes) >= SystemConf#system_conf.n ->
                                case leo_manager_api:detach(NodeAtom) of
                                    ok ->
                                        ?OK;
                                    {error, _} ->
                                        io_lib:format("[ERROR] ~s - ~s\r\n", [?ERROR_COULD_NOT_DETACH_NODE, Node])
                                end;
                            {ok, Nodes} when length(Nodes) =< SystemConf#system_conf.n ->
                                io_lib:format("[ERROR] ~s\r\n",["Attached nodes less than # of replicas"]);
                            _Error ->
                                io_lib:format("[ERROR] ~s\r\n",["Could not get node-status"])
                        end
                end
        end,
    {reply, Reply, State};


%% Command: "suspend ${NODE_NAME}"
%%
handle_call(_Socket, <<?SUSPEND, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    Reply = case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
                [] ->
                    io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_NODE_SPECIFIED]);
                [Node|_] ->
                    case leo_manager_api:suspend(list_to_atom(Node)) of
                        ok ->
                            ?OK;
                        {error, Cause} ->
                            io_lib:format("[ERROR] ~s\r\n",[Cause])
                    end
            end,
    {reply, Reply, State};


%% Command: "resume ${NODE_NAME}"
%%
handle_call(_Socket, <<?RESUME, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    Reply = case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
                [] ->
                    io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_NODE_SPECIFIED]);
                [Node|_] ->
                    case leo_manager_api:resume(list_to_atom(Node)) of
                        ok ->
                            ?OK;
                        {error, Cause} ->
                            io_lib:format("[ERROR] ~s\r\n",[Cause])
                    end
            end,
    {reply, Reply, State};


%% Command: "start"
%%
handle_call(_Socket, <<?START, _/binary>> = Command, State) ->
    Reply = case leo_manager_console_commons:start(Command) of
                ok ->
                    ?OK;
                {error, {bad_nodes, BadNodes}} ->
                    lists:foldl(fun(Node, Acc) ->
                                        Acc ++ io_lib:format("[ERROR] ~w\r\n", [Node])
                                end, [], BadNodes);
                {error, Cause} ->
                    io_lib:format("[ERROR] ~s\r\n",[Cause])
            end,
    {reply, Reply, State};


%% Command: "rebalance"
%%
handle_call(_Socket, <<?REBALANCE, _/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    Reply = case leo_redundant_manager_api:checksum(?CHECKSUM_RING) of
                {ok, {CurRingHash, PrevRingHash}} when CurRingHash =/= PrevRingHash ->
                    case leo_manager_api:rebalance() of
                        ok ->
                            ?OK;
                        _Other ->
                            io_lib:format("[ERROR] ~s\r\n",["fail rebalance"])
                    end;
                _Other ->
                    io_lib:format("[ERROR] ~s\r\n",["could not start"])
            end,
    {reply, Reply, State};


%%----------------------------------------------------------------------
%% Operation-2
%%----------------------------------------------------------------------
%% Command: "du ${NODE_NAME}"
%%
handle_call(_Socket, <<?STORAGE_STATS, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
            [] ->
                {io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_NODE_SPECIFIED]), State};
            Tokens ->
                Res = case length(Tokens) of
                          1 -> {summary, lists:nth(1, Tokens)};
                          2 -> {list_to_atom(lists:nth(1, Tokens)),  lists:nth(2, Tokens)};
                          _ -> {error, badarg}
                      end,

                case Res of
                    {error, _Cause} ->
                        {io_lib:format("[ERROR] ~s\r\n",[?ERROR_COMMAND_NOT_FOUND]), State};
                    {Option1, Node1} ->
                        case leo_manager_api:stats(Option1, Node1) of
                            {ok, StatsList} ->
                                {format_stats_list(Option1, StatsList), State};
                            {error, Cause} ->
                                {io_lib:format("[ERROR] ~s\r\n",[Cause]), State}
                        end
                end
        end,
    {reply, Reply, NewState};


%% Command: "compact ${NODE_NAME}"
%%
handle_call(_Socket, <<?COMPACT, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
            [] ->
                {io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_NODE_SPECIFIED]),State};
            [Node|_] ->
                case leo_manager_api:suspend(list_to_atom(Node)) of
                    ok ->
                        try
                            case leo_manager_api:compact(Node) of
                                {ok, _} ->
                                    {?OK, State};
                                {error, CompactionError} ->
                                    {io_lib:format("[ERROR] ~s\r\n",[CompactionError]), State}
                            end
                        after
                            leo_manager_api:resume(list_to_atom(Node))
                        end;
                    {error, SuspendError} ->
                        {io_lib:format("[ERROR] ~s\r\n",[SuspendError]), State}
                end
        end,
    {reply, Reply, NewState};


%%----------------------------------------------------------------------
%% Operation-3
%%----------------------------------------------------------------------
%% Command: "s3-gen-key ${USER_ID}"
%%
handle_call(_Socket, <<?S3_GEN_KEY, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
            [] ->
                {io_lib:format("[ERROR] ~s\r\n",["no user specified"]),State};
            [UserId|_] ->
                case leo_s3_auth:gen_key(UserId) of
                    {ok, Keys} ->
                        AccessKeyId     = proplists:get_value(access_key_id,     Keys),
                        SecretAccessKey = proplists:get_value(secret_access_key, Keys),
                        {io_lib:format("access-key-id: ~s\r\n"
                                       ++ "secret-access-key: ~s\r\n\r\n",
                                       [AccessKeyId, SecretAccessKey]), State};
                    {error, Cause} ->
                        {io_lib:format("[ERROR] ~s\r\n",[Cause]), State}
                end
        end,
    {reply, Reply, NewState};


%% Command: "s3-set-endpoint ${END_POINT}"
%%
handle_call(_Socket, <<?S3_SET_ENDPOINT, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
            [] ->
                {io_lib:format("[ERROR] ~s\r\n",[?ERROR_COMMAND_NOT_FOUND]),State};
            [EndPoint|_] ->
                case leo_s3_endpoint:set_endpoint(EndPoint) of
                    ok ->
                        {?OK, State};
                    {error, Cause} ->
                        {io_lib:format("[ERROR] ~s\r\n",[Cause]), State}
                end
        end,
    {reply, Reply, NewState};


%% Command: "s3-del-endpoint ${END_POINT}"
%%
handle_call(_Socket, <<?S3_DEL_ENDPOINT, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
            [] ->
                {io_lib:format("[ERROR] ~s\r\n",[?ERROR_COMMAND_NOT_FOUND]),State};
            [EndPoint|_] ->
                case leo_s3_endpoint:delete_endpoint(EndPoint) of
                    ok ->
                        {?OK, State};
                    not_found ->
                        {io_lib:format("[ERROR] ~s\r\n",[?ERROR_ENDPOINT_NOT_FOUND]),State};
                    {error, Cause} ->
                        {io_lib:format("[ERROR] ~s\r\n",[Cause]), State}
                end
        end,
    {reply, Reply, NewState};


%% Command: "s3-get-endpoints"
%%
handle_call(_Socket, <<?S3_GET_ENDPOINTS, _/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case leo_s3_endpoint:get_endpoints() of
            {ok, EndPoints} ->
                {format_endpoint_list(EndPoints), State};
            not_found ->
                {io_lib:format("not found\r\n", []), State};
            {error, Cause} ->
                {io_lib:format("[ERROR] ~s\r\n",[Cause]), State}
        end,
    {reply, Reply, NewState};


%% Command: "s3-get-buckets"
%%
handle_call(_Socket, <<?S3_GET_BUCKETS, _/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    {Reply, NewState} =
        case leo_s3_bucket:find_all_including_owner() of
            {ok, Buckets} ->
                {format_bucket_list(Buckets), State};
            not_found ->
                {io_lib:format("not found\r\n", []), State};
            {error, Cause} ->
                {io_lib:format("[ERROR] ~s\r\n",[Cause]), State}
        end,
    {reply, Reply, NewState};


%% Command: "whereis ${PATH}"
%%
handle_call(_Socket, <<?WHEREIS, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),

    Reply = case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
                [] ->
                    io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_PATH_SPECIFIED]);
                Key ->
                    HasRoutingTable = (leo_redundant_manager_api:checksum(ring) >= 0),

                    case catch leo_manager_api:whereis(Key, HasRoutingTable) of
                        {ok, AssignedInfo} ->
                            format_where_is(AssignedInfo);
                        {error, Cause} ->
                            io_lib:format("[ERROR] ~s\r\n", [Cause]);
                        _ ->
                            io_lib:format("[ERROR] ~s\r\n", [?ERROR_COMMAND_NOT_FOUND])
                    end
            end,
    {reply, Reply, State};


%% Command: "purge ${PATH}"
%%
handle_call(_Socket, <<?PURGE, Option/binary>> = Command, State) ->
    _ = leo_manager_mnesia:insert_history(Command),
    Reply = case string:tokens(binary_to_list(Option), ?COMMAND_DELIMITER) of
                [] ->
                    io_lib:format("[ERROR] ~s\r\n",[?ERROR_NO_PATH_SPECIFIED]);
                [Key|_] ->
                    case catch leo_manager_api:purge(Key) of
                        ok ->
                            ?OK;
                        {error, Cause} ->
                            io_lib:format("[ERROR] ~s\r\n", [Cause]);
                        _ ->
                            io_lib:format("[ERROR] ~s\r\n", [?ERROR_COMMAND_NOT_FOUND])
                    end
            end,
    {reply, Reply, State};


%% Command: "history"
%%
handle_call(_Socket, <<?HISTORY, _/binary>>, State) ->
    Reply = case leo_manager_mnesia:get_histories_all() of
                {ok, Histories} ->
                    format_history_list(Histories) ++ "\r\n";
                {error, Cause} ->
                    io_lib:format("[ERROR] ~p\r\n", [Cause])
            end,
    {reply, Reply, State};


%% Command: "quit"
%%
handle_call(_Socket, <<?QUIT>>, State) ->
    {close, <<?BYE>>, State};


handle_call(_Socket, <<?CRLF>>, State) ->
    {reply, "", State};


handle_call(_Socket, _Data, State) ->
    Reply = io_lib:format("[ERROR] ~s\r\n",[?ERROR_COMMAND_NOT_FOUND]),
    {reply, Reply, State}.

%%----------------------------------------------------------------------
%% Inner function(s)
%%----------------------------------------------------------------------
%% @doc Format a cluster-node list
%%
format_node_list(Props) ->
    SystemConf = proplists:get_value('system_config', Props),
    Version    = proplists:get_value('version',       Props),
    [RH0, RH1] = proplists:get_value('ring_hash',     Props),
    Nodes      = proplists:get_value('nodes',         Props),

    FormattedSystemConf =
        io_lib:format(lists:append(["[system config]\r\n",
                                    "             version : ~s\r\n",
                                    " # of replicas       : ~w\r\n",
                                    " # of successes of R : ~w\r\n",
                                    " # of successes of W : ~w\r\n",
                                    " # of successes of D : ~w\r\n",
                                    "           ring size : 2^~w\r\n",
                                    "    ring hash (cur)  : ~s\r\n",
                                    "    ring hash (prev) : ~s\r\n\r\n",
                                    "[node(s) state]\r\n"]),
                      [Version,
                       SystemConf#system_conf.n,
                       SystemConf#system_conf.r,
                       SystemConf#system_conf.w,
                       SystemConf#system_conf.d,
                       SystemConf#system_conf.bit_of_ring,
                       leo_hex:integer_to_hex(RH0),
                       leo_hex:integer_to_hex(RH1)
                      ]),
    format_system_conf_with_node_state(FormattedSystemConf, Nodes).


%% @doc Format a cluster node state
%% @private
-spec(format_node_state(#cluster_node_status{}) ->
             string()).
format_node_state(State) ->
    ObjContainer = State#cluster_node_status.avs,
    Directories  = State#cluster_node_status.dirs,
    RingHashes   = State#cluster_node_status.ring_checksum,
    Statistics   = State#cluster_node_status.statistics,

    io_lib:format(lists:append(["[config]\r\n",
                                "            version : ~s\r\n",
                                "      obj-container : ~p\r\n",
                                "            log-dir : ~s\r\n",
                                "  ring state (cur)  : ~w\r\n",
                                "  ring state (prev) : ~w\r\n",
                                "\r\n[erlang-vm status]\r\n",
                                "    total mem usage : ~w\r\n",
                                "   system mem usage : ~w\r\n",
                                "    procs mem usage : ~w\r\n",
                                "      ets mem usage : ~w\r\n",
                                "    # of procs      : ~w\r\n\r\n"]),
                  [State#cluster_node_status.version,
                   ObjContainer,
                   proplists:get_value('log',              Directories, []),
                   proplists:get_value('ring_cur',         RingHashes,  []),
                   proplists:get_value('ring_prev',        RingHashes,  []),
                   proplists:get_value('total_mem_usage',  Statistics, 0),
                   proplists:get_value('system_mem_usage', Statistics, 0),
                   proplists:get_value('proc_mem_usage',   Statistics, 0),
                   proplists:get_value('ets_mem_usage',    Statistics, 0),
                   proplists:get_value('num_of_procs',     Statistics, 0)
                  ]).


%% @doc Format a system-configuration w/node-state
%% @private
-spec(format_system_conf_with_node_state(string(), list()) ->
             string()).
format_system_conf_with_node_state(FormattedSystemConf, Nodes) ->
    Col1Len = lists:foldl(fun({_,N,_,_,_,_}, Acc) ->
                                  Len = length(N),
                                  case (Len > Acc) of
                                      true  -> Len;
                                      false -> Acc
                                  end
                          end, 0, Nodes) + 5,
    CellColumns = [{"type",        5},
                   {"node",  Col1Len},
                   {"state",      12},
                   {"ring (cur)", 14},
                   {"ring (prev)",14},
                   {"when",       28},
                   {"END",         0}],
    LenPerCol = lists:map(fun({_, Len}) -> Len end, CellColumns),

    Fun1 = fun(Col, {Type,Str}) ->
                   {Name, Len} = Col,
                   case Name of
                       "END" when Type =:= title -> {Type, Str ++ ?CRLF};
                       _ when Type =:= title andalso
                              Name =:= "node"-> {Type, " " ++ Str ++ string:left(Name, Len, $ )};
                       _ when Type =:= title -> {Type,        Str ++ string:left(Name, Len, $ )}
                   end
           end,
    {_, Header2} = lists:foldl(Fun1, {title,[]}, CellColumns),
    Sepalator = lists:foldl(
                  fun(N, L) -> L ++ N  end,
                  [], lists:duplicate(lists:sum(LenPerCol), "-")) ++ ?CRLF,

    Fun2 = fun(N, List) ->
                   {Type, Alias, State, RingHash0, RingHash1, When} = N,
                   FormattedDate = leo_date:date_format(When),
                   Ret = lists:append([" ",
                                       string:left(Type,          lists:nth(1,LenPerCol)),
                                       string:left(Alias,         lists:nth(2,LenPerCol)),
                                       string:left(State,         lists:nth(3,LenPerCol)),
                                       string:left(RingHash0,     lists:nth(4,LenPerCol)),
                                       string:left(RingHash1,     lists:nth(5,LenPerCol)),
                                       FormattedDate,
                                       ?CRLF]),
                   List ++ [Ret]
           end,
    _FormattedList =
        lists:foldl(Fun2, [FormattedSystemConf, Sepalator, Header2, Sepalator], Nodes) ++ ?CRLF.


%% @doc Format an assigned file
%% @private
-spec(format_where_is(list()) ->
             string()).
format_where_is(AssignedInfo) ->
    Col2Len = lists:foldl(fun(N, Acc) ->
                                  Len = length(element(1,N)),
                                  case (Len > Acc) of
                                      true  -> Len;
                                      false -> Acc
                                  end
                          end, 0, AssignedInfo) + 5,
    CellColumns = [{"del?",          5},
                   {"node",    Col2Len},
                   {"ring address", 36},
                   {"size",          8},
                   {"checksum",     12},
                   {"clock",        14},
                   {"when",         28},
                   {"END",           0}],

    LenPerCol = lists:map(fun({_, Len})-> Len end, CellColumns),
    Fun1 = fun(Col, {Type,Str}) ->
                   {Name, Len} = Col,
                   case Name of
                       "END" when Type =:= title -> {Type, Str ++ ?CRLF};
                       _ when Type =:= title andalso
                              Name =:= "node"-> {Type, " " ++ Str ++ string:left(Name, Len, $ )};
                       _ when Type =:= title -> {Type,        Str ++ string:left(Name, Len, $ )}
                   end
           end,
    {_, Header2} = lists:foldl(Fun1, {title,[]}, CellColumns),
    Sepalator = lists:foldl(
                  fun(N, L) -> L ++ N  end,
                  [], lists:duplicate(lists:sum(LenPerCol), "-")) ++ ?CRLF,

    Fun2 = fun(N, List) ->
                   Ret = case N of
                             {Node, not_found} ->
                                 lists:append([" ",
                                               string:left("", lists:nth(1,LenPerCol)),
                                               Node,
                                               ?CRLF]);
                             {Node, VNodeId, DSize, Clock, Timestamp, Checksum, DelFlag} ->
                                 FormattedDate = leo_date:date_format(Timestamp),
                                 DelStr = case DelFlag of
                                              0 -> " ";
                                              _ -> "*"
                                          end,
                                 lists:append([" ",
                                               string:left(DelStr,                            lists:nth(1,LenPerCol)),
                                               string:left(Node,                              lists:nth(2,LenPerCol)),
                                               string:left(leo_hex:integer_to_hex(VNodeId),   lists:nth(3,LenPerCol)),
                                               string:left(dsize(DSize),                      lists:nth(4,LenPerCol)),
                                               string:left(string:sub_string(leo_hex:integer_to_hex(Checksum), 1, 10),
                                                           lists:nth(5,LenPerCol)),
                                               string:left(leo_hex:integer_to_hex(Clock),     lists:nth(6,LenPerCol)),
                                               FormattedDate,
                                               ?CRLF])
                         end,
                   List ++ [Ret]
           end,
    _FormattedList =
        lists:foldl(Fun2, [Sepalator, Header2, Sepalator], AssignedInfo) ++ ?CRLF.


%% @doc Format s stats-list
%% @private
-spec(format_stats_list(summary | detail, {integer(), integer()} | list()) ->
             string()).
format_stats_list(summary, {FileSize, Total}) ->
    io_lib:format(lists:append(["              file size: ~w\r\n",
                                " number of total object: ~w\r\n\r\n"]), [FileSize, Total]);

format_stats_list(detail, StatsList) when is_list(StatsList) ->
    Fun = fun(Stats, Acc) ->
                  case Stats of
                      {ok, #storage_stats{file_path   = FilePath,
                                          total_sizes = FileSize,
                                          total_num   = ObjTotal}} ->
                          Acc ++ io_lib:format(lists:append(["              file path: ~s\r\n",
                                                             "              file size: ~w\r\n",
                                                             " number of total object: ~w\r\n"]),
                                               [FilePath, FileSize, ObjTotal]);
                      _Error ->
                          Acc
                  end
          end,
    lists:append([lists:foldl(Fun, "[du(storage stats)]\r\n", StatsList), "\r\n"]);

format_stats_list(_, _) ->
    [].



%% @doc Format a history list
%% @private
-spec(format_history_list(list(#history{})) ->
             string()).
format_history_list(Histories) ->
    Fun = fun(#history{id      = Id,
                       command = Command,
                       created = Created}, Acc) ->
                  Acc ++ io_lib:format("~s | ~s | ~s\r\n",
                                       [string:left(integer_to_list(Id), 4), leo_date:date_format(Created), Command])
          end,
    lists:foldl(Fun, "[Histories]\r\n", Histories).


%% @doc Format a endpoint list
%% @private
-spec(format_endpoint_list(list(tuple())) ->
             string()).
format_endpoint_list(EndPoints) ->
    Col1Len = lists:foldl(fun({_, EP, _}, Acc) ->
                                  Len = length(EP),
                                  case (Len > Acc) of
                                      true  -> Len;
                                      false -> Acc
                                  end
                          end, 0, EndPoints),
    Col2Len = 26,

    Header = lists:append([string:left("endpoint", Col1Len), " | ", string:left("created at", Col2Len), "\r\n",
                           lists:duplicate(Col1Len, "-"),    "-+-", lists:duplicate(Col2Len, "-"),      "\r\n"]),
    Fun = fun({endpoint, EP, Created}, Acc) ->
                  Acc ++ io_lib:format("~s | ~s\r\n",
                                       [string:left(EP,Col1Len), leo_date:date_format(Created)])
          end,
    lists:append([lists:foldl(Fun, Header, EndPoints), "\r\n"]).


%% @doc Format a bucket list
%% @private
-spec(format_bucket_list(list(tuple())) ->
             string()).
format_bucket_list(Buckets) ->
    {Col1Len, Col2Len} = lists:foldl(fun({Bucket, Owner, _}, {C1, C2}) ->
                                             Len1 = length(Bucket),
                                             Len2 = length(Owner),

                                             {case (Len1 > C1) of
                                                  true  -> Len1;
                                                  false -> C1
                                              end,
                                              case (Len2 > C2) of
                                                  true  -> Len2;
                                                  false -> C2
                                              end}
                                     end, {0,0}, Buckets),
    Col3Len = 26,
    Header = lists:append(
               [string:left("bucket",     Col1Len), " | ",
                string:left("owner",      Col2Len), " | ",
                string:left("created at", Col3Len), "\r\n",

                lists:duplicate(Col1Len, "-"), "-+-",
                lists:duplicate(Col2Len, "-"), "-+-",
                lists:duplicate(Col3Len, "-"), "\r\n"]),

    Fun = fun({Bucket, Owner, Created}, Acc) ->
                  Acc ++ io_lib:format("~s | ~s | ~s\r\n",
                                       [string:left(Bucket, Col1Len),
                                        string:left(Owner,  Col2Len),
                                        leo_date:date_format(Created)])
          end,
    lists:append([lists:foldl(Fun, Header, Buckets), "\r\n"]).


%% @doc Retrieve data-size w/unit.
%% @private
-define(FILE_KB,       1024).
-define(FILE_MB,    1048586).
-define(FILE_GB, 1073741824).

dsize(Size) when Size =< ?FILE_KB -> integer_to_list(Size) ++ "B";
dsize(Size) when Size  > ?FILE_KB -> integer_to_list(erlang:round(Size / ?FILE_KB)) ++ "K";
dsize(Size) when Size  > ?FILE_MB -> integer_to_list(erlang:round(Size / ?FILE_MB)) ++ "M";
dsize(Size) when Size  > ?FILE_GB -> integer_to_list(erlang:round(Size / ?FILE_GB)) ++ "G".
