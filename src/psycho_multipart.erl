-module(psycho_multipart).

-export([new/1, new/2, data/2, form_data/1]).

-record(mp, {boundary_delim, parts, headers, acc}).

new(Boundary) ->
    new(Boundary, {undefined, undefined}).

new(Boundary, {_Callback, _Data}) when is_binary(Boundary) ->
    #mp{
       boundary_delim=boundary_delim(Boundary),
       parts=[],
       headers=pending,
       acc=[]}.

boundary_delim(Boundary) ->
    <<"--", Boundary/binary>>.

data(Data, MP) ->
    try_boundary(Data, MP).

try_boundary(Data, #mp{boundary_delim=Delim}=MP) ->
    Window = search_window(Data, MP),
    handle_boundary_match(binary:match(Window, Delim), Window, Data, MP).

search_window(Data, #mp{acc=[]}) -> Data;
search_window(Data, #mp{acc=[Last|_]}) -> join(Last, Data).

join(B1, B2) -> <<B1/binary, B2/binary>>.

handle_boundary_match(nomatch, Window, Data, MP) ->
    try_headers(Window, Data, MP);
handle_boundary_match({Pos, Len}, Window, _Data, MP) ->
    <<Prev:Pos/binary, _:Len/binary, Next/binary>> = Window,
    new_part(Next, finalize_part(Prev, MP)).

finalize_part(<<>>, MP) -> MP;
finalize_part(Data, #mp{acc=Acc}=MP) ->
    add_cur(try_headers(Data, MP#mp{acc=pop_last(Acc)})).

pop_last([]) -> [];
pop_last([_|Rest]) -> Rest.

try_headers(Data, MP) ->
    try_headers(Data, Data, MP).

-define(HEADERS_DELIM, <<"\r\n\r\n">>).

try_headers(Window, Data, #mp{headers=pending}=MP) ->
    handle_match_headers(
      binary:match(Window, ?HEADERS_DELIM),
      Window, Data, MP);
try_headers(_Window, Data, #mp{acc=Acc}=MP) ->
    MP#mp{acc=[Data|Acc]}.

handle_match_headers(nomatch, _Window, Data, #mp{acc=Acc}=MP) ->
    MP#mp{acc=[Data|Acc]};
handle_match_headers({Pos, Len}, Window, _Data, MP) ->
    <<Prev:Pos/binary, _:Len/binary, Next/binary>> = Window,
    start_body(Next, finalize_headers(Prev, MP)).

finalize_headers(Data, #mp{acc=Acc}=MP) ->
    Raw = iolist_to_binary(lists:reverse([Data|pop_last(Acc)])),
    Headers = parse_headers(Raw),
    MP#mp{headers=Headers}.

parse_headers(<<"\r\n", Raw/binary>>) ->
    [parse_header(Part) || Part <- split_headers(Raw)];
parse_headers(_) -> [].

split_headers(Raw) ->
    binary:split(Raw, <<"\r\n">>, [global]).

parse_header(Raw) ->
    case binary:split(Raw, <<":">>) of
        [Name, RawVal] -> {binary_to_list(Name), header_val(RawVal)};
        [Name] -> {binary_to_list(Name), <<>>}
    end.

header_val(<<" ", Val/binary>>) -> binary_to_list(Val);
header_val(Val) -> binary_to_list(Val).

start_body(Data, MP) -> MP#mp{acc=[Data]}.

add_cur(#mp{headers=Headers, acc=Acc, parts=Parts}=MP) ->
    Name = form_data_name(Headers),
    Body = finalize_body(Acc),
    Part = {Name, Headers, Body},
    MP#mp{parts=[Part|Parts], headers=pending, acc=[]}.

-define(FORM_DATA_NAME_RE, <<"form-data; *name=\"(.*?)\"">>).

form_data_name(Headers) ->
    Disp = proplists:get_value("Content-Disposition", Headers, ""),
    handle_form_data_name_re(
      re:run(Disp, ?FORM_DATA_NAME_RE, [{capture, [1], list}])).

handle_form_data_name_re({match, [Name]}) -> Name;
handle_form_data_name_re(nomatch) -> <<>>.

finalize_body([]) -> <<>>;
finalize_body([Last|Rest]) ->
    LastTrimmed = strip_trailing_crlf(Last),
    iolist_to_binary(lists:reverse([LastTrimmed|Rest])).

strip_trailing_crlf(Bin) ->
    N = size(Bin) - 2,
    case Bin of
        <<Stripped:N/binary, "\r\n">> -> Stripped;
        _ -> Bin
    end.

new_part(Data, MP) ->
    try_headers(Data, MP).

form_data(#mp{parts=Parts}) ->
    lists:reverse(Parts).