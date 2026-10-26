#!/usr/bin/env escript
%%! -noinput
main(Args) ->
    Mode = mode(Args),
    Port = open_port({fd, 0, 1}, [{packet, 4}, binary, eof]),
    loop(Port, Mode).

mode(["--module", Mode | _]) -> Mode;
mode([_ | Rest]) -> mode(Rest);
mode([]) -> "ok".

loop(Port, Mode) ->
    receive
        {Port, {data, <<1, Id:32, Op, Body/binary>>}} ->
            reply(Port, Mode, Id, Op, Body),
            loop(Port, Mode);
        {Port, eof} ->
            halt(0)
    end.

reply(_Port, "crash", _Id, 1, _Body) ->
    halt(3);
reply(_Port, "hang", _Id, 1, _Body) ->
    ok;
reply(Port, "garbage", _Id, 1, _Body) ->
    port_command(Port, <<9, 9>>);
reply(Port, "stale", Id, 1, Body) ->
    frame(Port, Id + 1000, 0, [<<"stale">>]),
    reply(Port, "ok", Id, 1, Body);
reply(Port, _Mode, Id, 0, <<>>) ->
    frame(Port, Id, 0, []);
reply(Port, _Mode, Id, 1, <<_Alg, L:32, _Label:L/binary, M:32, Message:M/binary>>) ->
    frame(Port, Id, 0, [Message]);
reply(Port, _Mode, Id, 2, <<2, _/binary>>) ->
    frame(Port, Id, 0, [<<"n">>, <<"e">>]);
reply(Port, _Mode, Id, 2, _Body) ->
    frame(Port, Id, 3, [<<"key not found">>]);
reply(Port, _Mode, Id, 3, <<L:32, _:L/binary, A:32, _:A/binary, P:32, Plain:P/binary>>) ->
    frame(Port, Id, 0, [<<"w", Plain/binary>>]);
reply(Port, _Mode, Id, 4, <<L:32, _:L/binary, A:32, _:A/binary, _W:32, "w", Plain/binary>>) ->
    frame(Port, Id, 0, [Plain]);
reply(Port, _Mode, Id, _Op, _Body) ->
    frame(Port, Id, 4, [<<"wrapped key failed authentication">>]).

frame(Port, Id, Status, Fields) ->
    port_command(Port, [<<1, Id:32, Status>> | [[<<(byte_size(F)):32>>, F] || F <- Fields]]).
