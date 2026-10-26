-module(dagger_ffi).
-export([connect/1, request/3, close/1, with_cleanup/2]).

connect(Timeout) when is_integer(Timeout), Timeout > 0 ->
    case {os:getenv("DAGGER_SESSION_PORT"), os:getenv("DAGGER_SESSION_TOKEN")} of
        {false, false} -> start_session(Timeout);
        {false, _} -> {error, <<"DAGGER_SESSION_PORT is missing">>};
        {_, false} -> {error, <<"DAGGER_SESSION_TOKEN is missing">>};
        {Port, Token} -> session(Port, list_to_binary(Token), undefined)
    end;
connect(_) -> {error, <<"Timeout must be positive">>}.

session(Port0, Token, Owner) ->
    try
        Port = case Port0 of N when is_integer(N) -> N; _ -> list_to_integer(Port0) end,
        true = Port > 0 andalso Port < 65536,
        true = is_binary(Token) andalso byte_size(Token) > 0,
        {ok, {session, Port, Token, Owner}}
    catch _:_ -> {error, <<"Invalid Dagger session port or token">>} end.

start_session(Timeout) ->
    Bin = case os:getenv("_EXPERIMENTAL_DAGGER_CLI_BIN") of
        false -> os:find_executable("dagger");
        Value -> os:find_executable(Value)
    end,
    case Bin of
        false -> {error, <<"Dagger CLI not found in PATH">>};
        _ ->
            Parent = self(), Ref = make_ref(),
            {Pid, Mon} = spawn_monitor(fun() -> session_owner(Parent, Ref, Bin) end),
            receive
                {Ref, Result} -> erlang:demonitor(Mon, [flush]), Result;
                {'DOWN', Mon, process, Pid, _} -> {error, <<"Dagger session exited before connecting">>}
            after Timeout ->
                exit(Pid, kill),
                receive {'DOWN', Mon, process, Pid, _} -> ok end,
                receive {Ref, _} -> ok after 0 -> ok end,
                {error, <<"Timed out starting Dagger session">>}
            end
    end.

session_owner(Parent, Ref, Bin) ->
    process_flag(trap_exit, true),
    Mon = monitor(process, Parent),
    try open_port({spawn_executable, Bin}, [binary, exit_status, use_stdio,
        {line, 1048576}, {args, ["session", "--label", "dagger.io/sdk.name:gleam",
            "--label", "dagger.io/sdk.version:0.1.0"]}]) of
        Port -> await_session(Parent, Ref, Mon, Port, <<>>)
    catch _:_ -> Parent ! {Ref, {error, <<"Could not start Dagger CLI">>}} end.

await_session(Parent, Ref, Mon, Port, Buffer) ->
    receive
        {Port, {data, {noeol, Data}}} when byte_size(Buffer) + byte_size(Data) < 4194304 ->
            await_session(Parent, Ref, Mon, Port, <<Buffer/binary, Data/binary>>);
        {Port, {data, {eol, Data}}} ->
            Line = <<Buffer/binary, Data/binary>>,
            Parsed = try json:decode(Line) catch _:_ -> #{} end,
            case Parsed of
                #{<<"port">> := Number, <<"session_token">> := Token} ->
                    Result = session(Number, Token, self()),
                    Parent ! {Ref, Result},
                    case Result of {ok, _} -> session_loop(Mon, Port); _ -> safe_close_port(Port) end;
                _ -> await_session(Parent, Ref, Mon, Port, <<>>)
            end;
        {'DOWN', Mon, process, Parent, _} -> safe_close_port(Port);
        {Port, {exit_status, Status}} ->
            Parent ! {Ref, {error, iolist_to_binary(io_lib:format("Dagger CLI exited (~p)", [Status]))}};
        {'EXIT', Port, _} -> Parent ! {Ref, {error, <<"Dagger CLI port closed">>}}
    end.

session_loop(Mon, Port) ->
    receive
        {stop, From, Ref} -> safe_close_port(Port), From ! {Ref, stopped};
        {'DOWN', Mon, process, _, _} -> safe_close_port(Port);
        {Port, {exit_status, _}} -> ok;
        {'EXIT', Port, _} -> ok;
        _ -> session_loop(Mon, Port)
    end.

close({session, _, _, undefined}) -> nil;
close({session, _, _, Pid}) ->
    Ref = make_ref(), Mon = monitor(process, Pid),
    Pid ! {stop, self(), Ref},
    receive
        {Ref, stopped} -> demonitor(Mon, [flush]);
        {'DOWN', Mon, process, Pid, _} -> ok
    after 5000 -> exit(Pid, kill), demonitor(Mon, [flush]) end,
    nil.

request({session, Port, Token, _}, Body, Timeout) ->
    case application:ensure_all_started(inets) of
        {ok, _} ->
            Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/query",
            Auth = "Basic " ++ binary_to_list(base64:encode(<<Token/binary, ":">>)),
            case httpc:request(post, {Url, [{"authorization", Auth}], "application/json", Body},
                [{timeout, Timeout}, {connect_timeout, Timeout}, {autoredirect, false}],
                [{body_format, binary}]) of
                {ok, {{_, Status, _}, _, Response}} -> {ok, {Status, Response}};
                {error, _} -> {error, <<"Dagger HTTP request failed">>}
            end;
        _ -> {error, <<"Could not start Erlang inets">>}
    end.

with_cleanup(Fun, Cleanup) -> try Fun() after Cleanup() end.

safe_close_port(Port) -> try port_close(Port) catch error:badarg -> ok end.
