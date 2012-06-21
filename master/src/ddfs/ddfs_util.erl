-module(ddfs_util).
-export([read_file/1,
         write_file/2,
         make_dir/1,
         list_dir/1,
         read_file/2,
         write_file/3,
         make_dir/2,
         list_dir/2,
         choose_random/1,
         choose_random/2,
         concatenate/2,
         diskspace/1,
         ensure_dir/1,
         fold_files/3,
         diskspace/2,
         ensure_dir/2,
         fold_files/4,
         format_timestamp/0,
         hashdir/5,
         hashdir/6,
         is_valid_name/1,
         pack_objname/2,
         parse_url/1,
         cluster_url/2,
         safe_rename/2,
         safe_rename/3,
         startswith/2,
         timestamp/0,
         timestamp/1,
         timestamp_to_time/1,
         to_hex/1,
         unpack_objname/1,
         unpack_objname/2,
         url_to_name/1]).

-include_lib("kernel/include/file.hrl").

-include("common_types.hrl").
-include("config.hrl").
-include("ddfs.hrl").
-include("ddfs_tag.hrl").

-spec is_valid_name(path()) -> boolean().
is_valid_name([]) -> false;
is_valid_name(Name) when length(Name) > ?NAME_MAX -> false;
is_valid_name(Name) ->
    Ok = ":@-_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
    not lists:any(fun(C) -> string:chr(Ok, C) =:= 0 end, Name).

-spec startswith(binary(), binary()) -> boolean().
startswith(B, Prefix) when size(B) < size(Prefix) ->
    false;
startswith(B, Prefix) ->
    {Head, _} = split_binary(B, size(Prefix)),
    Head =:= Prefix.

-spec timestamp() -> string().
timestamp() -> timestamp(now()).

-spec timestamp(erlang:timestamp()) -> string().
timestamp({X0, X1, X2}) ->
    lists:flatten([to_hex(X0), $-, to_hex(X1), $-, to_hex(X2)]).

-spec timestamp_to_time(nonempty_string()) -> erlang:timestamp().
timestamp_to_time(T) ->
    list_to_tuple([erlang:list_to_integer(X, 16) ||
        X <- string:tokens(lists:flatten(T), "-")]).

-spec pack_objname(tagname(), erlang:timestamp()) -> tagid().
pack_objname(Name, T) ->
    list_to_binary([Name, "$", timestamp(T)]).

-spec unpack_objname(tagid() | string()) -> {binary(), erlang:timestamp()}.
unpack_objname(Obj) ->
    unpack_objname(std_node, Obj).

-spec unpack_objname(s3_node | std_node, tagid() | string()) -> {binary(), erlang:timestamp()}.
unpack_objname(s3_node, Obj) ->
    unpack_objname(std_node, Obj);
unpack_objname(std_node, Obj) when is_binary(Obj) ->
    unpack_objname(std_node, binary_to_list(Obj));
unpack_objname(std_node, Obj) ->
    [Name, Tstamp] = string:tokens(Obj, "$"),
    {list_to_binary(Name), timestamp_to_time(Tstamp)}.

-spec url_to_name(binary()) -> binary() | 'false'.
url_to_name(<<"tag://", Name/binary>>) ->
    Name;
url_to_name(Url) ->
    case re:run(Url, "/../(.*)[$]", [{capture, all_but_first, binary}]) of
        {match, [Name]} ->
            Name;
        _ ->
            false
    end.

-spec ensure_dir(string()) -> 'eof' | 'ok' | {'error', _} | {'ok', _}.
ensure_dir(Dir) ->
    ensure_dir(std_node, Dir).

-spec ensure_dir(s3_node | std_node, string()) -> 'eof' | 'ok' | {'error', _} | {'ok', _}.
ensure_dir(s3_node, Dir) ->
    ensure_dir(std_node, Dir);
ensure_dir(std_node, Dir) ->
    case prim_file:make_dir(Dir) of
        ok -> ok;
        {error, eexist} -> ok;
        E -> E
    end.

-spec format_timestamp() -> binary().
format_timestamp() ->
    {Date, Time} = calendar:now_to_local_time(now()),
    DateStr = io_lib:fwrite("~w/~.2.0w/~.2.0w ", tuple_to_list(Date)),
    TimeStr = io_lib:fwrite("~.2.0w:~.2.0w:~.2.0w", tuple_to_list(Time)),
    list_to_binary([DateStr, TimeStr]).

-spec to_hex(non_neg_integer()) -> nonempty_string().
to_hex(Int) ->
    to_hex(Int, []).

-spec to_hex(non_neg_integer(), string()) -> nonempty_string().
to_hex(Int, L) ->
    case {Int, L} of
        {0, []} -> "00";
        {0, _ } -> L;
        _ ->
            D = Int div 16,
            R = Int rem 16,
            C = if R < 10 -> $0 + R;
                   true   -> $a + R - 10
                end,
            to_hex(D, [C|L])
    end.

-spec hashdir(binary(), nonempty_string(), nonempty_string(),
    nonempty_string(), nonempty_string()) -> {'ok', string(), binary()}.
hashdir(Name, Host, Type, Root, Vol) ->
    hashdir(std_node, Name, Host, Type, Root, Vol).

-spec hashdir(s3_node | std_node, binary(), nonempty_string(), nonempty_string(),
              nonempty_string(), nonempty_string()) -> {'ok', string(), binary()}.
hashdir(s3_node, Name, Host, Type, Root, Vol) ->
    hashdir(std_node, Name, Host, Type, Root, Vol);
hashdir(std_node, Name, Host, Type, Root, Vol) ->
    <<D0:8, _/binary>> = erlang:md5(Name),
    D1 = to_hex(D0),
    Dir = lists:flatten([case D1 of [_] -> "0"; _ -> "" end, D1]),
    Path = filename:join([Vol, Type, Dir]),
    Url = list_to_binary(["disco://", Host, "/ddfs/", Path, "/", Name]),
    Local = filename:join(Root, Path),
    {ok, Local, Url}.

-spec parse_url(binary() | string()) ->
        'not_ddfs' | {host(), volume_name(), object_type(), string(), object_name()}.
parse_url(Url) when is_binary(Url) ->
    parse_url(binary_to_list(Url));
parse_url(Url) when is_list(Url) ->
    {_S, Host, Path, _Q, _F} = mochiweb_util:urlsplit(Url),
    case filename:split(Path) of
        ["/","ddfs","vol" ++ _ = Vol, "blob", Hash, Obj] ->
            {Host, Vol, blob, Hash, list_to_binary(Obj)};
        ["/","ddfs","vol" ++ _ = Vol, "tag", Hash, Obj] ->
            {Host, Vol, tag, Hash, list_to_binary(Obj)};
        _ -> not_ddfs
    end.

-type method() :: get | put.
-spec cluster_url(binary() | string(), method()) -> string().
cluster_url(Url, Meth) when is_binary(Url) ->
    cluster_url(binary_to_list(Url), Meth);
cluster_url(Url, Meth) when is_list(Url) ->
    cluster_url(Url, Meth, disco:local_cluster()).
cluster_url(Url, _Meth, false) -> Url;
cluster_url(Url, Meth, true) ->
    Method = string:to_upper(atom_to_list(Meth)),
    ProxyPort = disco:get_setting("DISCO_PROXY_PORT"),
    U = binary_to_list(list_to_binary(Url)),
    {S, HostPort, Path, _Q, _F} = mochiweb_util:urlsplit(U),
    Host = case string:tokens(HostPort, ":") of
               [H] -> H;
               [H|_] -> H
           end,
    ProxyUrl = [S, "://127.0.0.1:", ProxyPort, "/proxy/",
                Host, "/", Method, Path],
    lists:flatten(ProxyUrl).

-spec safe_rename(string(), string()) -> 'ok' | {'error', 'file_exists'
    | {'chmod_failed', _} | {'rename_failed', _}}.
safe_rename(Src, Dst) ->
    safe_rename(std_node, Src, Dst).

-spec safe_rename(s3_node | std_node, string(), string()) -> 'ok' | {'error', 'file_exists'
    | {'chmod_failed', _} | {'rename_failed', _}}.
safe_rename(s3_node, Src, Dst) ->
    safe_rename(std_node, Src, Dst);
safe_rename(std_node, Src, Dst) ->
    case prim_file:read_file_info(Dst) of
        {error, enoent} ->
            case prim_file:write_file_info(Src,
                    #file_info{mode = ?FILE_MODE}) of
                ok ->
                    case prim_file:rename(Src, Dst) of
                        ok -> ok;
                        {error, E} -> {error, {rename_failed, E}}
                    end;
                {error, E} -> {error, {chmod_failed, E}}
            end;
        _ -> {error, file_exists}
    end.

-spec concatenate(file:filename(), file:filename()) -> 'ok' | {'error', term()}.
concatenate(Src, Dst) ->
    {ok, SrcIO} = prim_file:open(Src, [read, raw, binary]),
    {ok, DstIO} = prim_file:open(Dst, [append, raw]),
    R = concatenate_do(SrcIO, DstIO),
    _ = prim_file:close(SrcIO),
    _ = prim_file:close(DstIO),
    R.

concatenate_do(SrcIO, DstIO) ->
    case prim_file:read(SrcIO, 524288) of
        {ok, Data} ->
            case prim_file:write(DstIO, Data) of
                ok -> concatenate_do(SrcIO, DstIO);
                Error -> Error
            end;
        eof ->
            ok;
        Error ->
            Error
    end.

-spec diskspace(nonempty_string()) ->
    {'error', 'invalid_output' | 'invalid_path'} | {'ok', diskinfo()}.
diskspace(Path) ->
    diskspace(std_node, Path).

-spec diskspace(s3_node | std_node, nonempty_string()) ->
    {'error', 'invalid_output' | 'invalid_path'} | {'ok', diskinfo()}.
diskspace(s3_node, Path) ->
    diskspace(std_node, Path);
diskspace(std_node, Path) ->
    case lists:reverse(string:tokens(os:cmd(["df -k ", Path]), "\n\t ")) of
        [_, _, Free, Used|_] ->
            case catch {list_to_integer(Free),
                        list_to_integer(Used)} of
                {F, U} when is_integer(F), is_integer(U), F >= 0, U >= 0 ->
                    {ok, {F, U}};
                _ ->
                    {error, invalid_path}
            end;
        _ ->
            {error, invalid_output}
    end.

-spec fold_files(string(), fun((string(), string(), T) -> T), T) -> T.
fold_files(Dir, Fun, Acc0) ->
    fold_files(std_node, Dir, Fun, Acc0).

-spec fold_files(s3_node | std_node, string(), fun((string(), string(), T) -> T), T) -> T.
fold_files(s3_node, Dir, Fun, Acc0) ->
    fold_files(std_node, Dir, Fun, Acc0);
fold_files(std_node, Dir, Fun, Acc0) ->
    {ok, L} = prim_file:list_dir(Dir),
    lists:foldl(fun(F, Acc) ->
        Path = filename:join(Dir, F),
        case prim_file:read_file_info(Path) of
            {ok, #file_info{type = directory}} ->
                fold_files(Path, Fun, Acc);
            _ ->
                Fun(F, Dir, Acc)
        end
    end, Acc0, L).

-spec choose_random([T,...]) -> T.
choose_random(L) ->
    lists:nth(random:uniform(length(L)), L).

-spec choose_random(list(T), non_neg_integer()) -> list(T).
choose_random(L, N) ->
    choose_random(L, [], N).

choose_random([], R, _) -> R;
choose_random(_, R, 0) -> R;
choose_random(L, R, N) ->
    C = choose_random(L),
    choose_random(L -- [C], [C|R], N - 1).

-spec read_file(list() | binary()) -> {ok, binary()} | {error, term()}.
read_file(TagPath) ->
    read_file(std_node, TagPath).

-spec read_file(s3_node | std_node, list() | binary()) -> {ok, binary()} | {error, term()}.
read_file(s3_node, TagPath) ->
    disco_aws:read(get(s3_bucket), TagPath);
read_file(std_node, TagPath) ->
    prim_file:read_file(TagPath).

-spec write_file(list() | binary(), binary()) -> ok | {error, term()}.
write_file(Filename, Data) ->
    write_file(std_node, Filename, Data).

-spec write_file(s3_node | std_node, list() | binary(), binary()) -> ok | {error, term()}.
write_file(s3_node, Filename, Data) ->
    disco_aws:spawn_put(get(s3_bucket), Filename, Data);
write_file(std_node, Filename, Data) ->
    prim_file:write_file(Filename, Data).

-spec make_dir(list()) -> ok.
make_dir(Dir) ->
    make_dir(std_node, Dir).

-spec make_dir(s3_node | std_node, list()) -> ok.
make_dir(s3_node, Dir) ->
    make_dir(std_node, Dir);
make_dir(std_node, Dir) ->
    prim_file:make_dir(Dir).

-spec list_dir(list()) -> {ok, list()} | {error, term()}.                         
list_dir(Root) ->
    list_dir(std_node, Root).

-spec list_dir(s3_node | std_node, list()) -> {ok, list()} | {error, term()}.          
list_dir(s3_node, Root) ->
    disco_aws:list_objects(Root);
list_dir(std_node, Root) ->
    prim_file:list_dir(Root).
