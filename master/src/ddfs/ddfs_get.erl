
-module(ddfs_get).

-include_lib("kernel/include/file.hrl").

-include("config.hrl").
-include("ddfs.hrl").

-export([start/2, serve_ddfs_file/2, serve_disco_file/2]).

-spec start(term(), {path(), path()}) -> {ok, pid()} | {error, term()}.
start(MochiConfig, Roots) ->
    error_logger:info_msg("Starting ~p on ~p", [?MODULE, node()]),
    mochiweb_http:start([
        {name, ddfs_get},
        {max, ?HTTP_MAX_CONNS},
        {loop, fun(Req) ->
                    loop(Req:get(raw_path), Req, Roots)
                end}
        | MochiConfig]).

-spec serve_ddfs_file(path(), module()) -> _.
serve_ddfs_file(Path, Req) ->
    DdfsRoot = disco:get_setting("DDFS_DATA"),
    loop(Path, Req, {DdfsRoot, none}).

-spec serve_disco_file(path(), module()) -> _.
serve_disco_file(Path, Req) ->
    DiscoRoot = disco:get_setting("DISCO_DATA"),
    loop(Path, Req, {none, DiscoRoot}).

-spec loop(path(), module(), {path() | none, path() | none}) -> _.
loop("/proxy/" ++ Path, Req, Roots) ->
    {_Node, Rest} = mochiweb_util:path_split(Path),
    {_Method, RealPath} = mochiweb_util:path_split(Rest),
    loop([$/|RealPath], Req, Roots);

loop("/ddfs/" ++ Path, Req, {DdfsRoot, _DiscoRoot}) ->
    send_file(Req, Path, DdfsRoot);

loop("/disco/" ++ Path, Req, {_DdfsRoot, DiscoRoot}) ->
    send_file(Req, Path, DiscoRoot);

loop(_Path, Req, _Roots) ->
    Req:not_found().

allowed_method('GET') ->
    true;
allowed_method('HEAD') ->
    true;
allowed_method(_) ->
    false.

-spec send_file(module(), path(), path()) -> _.
send_file(Req, Path, Root) ->
    % Disable keep-alive
    erlang:put(mochiweb_request_force_close, true),
    case {allowed_method(Req:get(method)),
          mochiweb_util:safe_relative_path(Path)} of
        {true, undefined} ->
            Req:not_found();
        {true, SafePath} ->
            case catch ddfs_node:gate_get_blob() of
                ok ->
                    send_file(Req, filename:join(Root, SafePath));
                {'EXIT', {noproc, _}} ->
                    Req:respond({403, [],
                                 ["Disco node is not running on this host"]});
                _ ->
                    Req:respond({503, [],
                                 ["Maximum number of downloaders reached. ",
                                  "Try again later"]})
            end;
        _ ->
            Req:respond({501, [], ["Method not supported"]})
    end.

-spec send_file(module(), path()) -> _.
send_file(Req, Path) ->
    case prim_file:read_file_info(Path) of
        {ok, #file_info{type = regular}} ->
            case file:open(Path, [read, raw, binary]) of
                {ok, IO} ->
                    Req:ok({"application/octet-stream", [], {file, IO}}),
                    file:close(IO);
                _ ->
                    Req:respond({500, [], ["Access failed"]})
            end;
        {ok, _} ->
            Req:respond({403, [], ["Forbidden"]});
        {error, enoent} ->
            Req:not_found();
        _ ->
            Req:respond({500, [], ["Access failed"]})
    end.
