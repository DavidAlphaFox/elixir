%% Translate Elixir quoted expressions to Erlang Abstract Format.
%% Expects the tree to be expanded.
%% 将Elixir的语法翻译成Erlang的抽象语法形式
-module(elixir_translator).
-export([translate/2, translate_arg/3, translate_args/2]).
-import(elixir_scope, [mergev/2, mergec/2]).
-import(elixir_errors, [compile_error/3, compile_error/4]).
-include("elixir.hrl").

%% =

translate({'=', Meta, [{'_', _, Atom}, Right]}, S) when is_atom(Atom) ->
  {TRight, SR} = translate(Right, S),
  {{match, ?line(Meta), {var, ?line(Meta), '_'}, TRight}, SR};

translate({'=', Meta, [Left, Right]}, S) ->
  {TRight, SR} = translate(Right, S),
  {TLeft, SL} = elixir_clauses:match(fun translate/2, Left, SR),
  {{match, ?line(Meta), TLeft, TRight}, SL};

%% Containers

translate({'{}', Meta, Args}, S) when is_list(Args) ->
  {TArgs, SE} = translate_args(Args, S),
  {{tuple, ?line(Meta), TArgs}, SE};

translate({'%{}', Meta, Args}, S) when is_list(Args) ->
  elixir_map:translate_map(Meta, Args, S);

translate({'%', Meta, [Left, Right]}, S) ->
  elixir_map:translate_struct(Meta, Left, Right, S);

translate({'<<>>', Meta, Args}, S) when is_list(Args) ->
  elixir_bitstring:translate(Meta, Args, S);

%% Blocks

translate({'__block__', Meta, Args}, S) when is_list(Args) ->
  {TArgs, SA} = translate_block(Args, [], S),
  {{block, ?line(Meta), TArgs}, SA};

%% Erlang op

translate({{'.', _, [erlang, 'andalso']}, Meta, [Left, Right]}, S) ->
  {[TLeft, TRight], NS}  = translate_args([Left, Right], S),
  {{op, ?line(Meta), 'andalso', TLeft, TRight}, NS};

translate({{'.', _, [erlang, 'orelse']}, Meta, [Left, Right]}, S) ->
  {[TLeft, TRight], NS}  = translate_args([Left, Right], S),
  {{op, ?line(Meta), 'orelse', TLeft, TRight}, NS};

%% Lexical

translate({Lexical, _, [_, _]}, S) when Lexical == import; Lexical == alias; Lexical == require ->
  {{atom, 0, nil}, S};

%% Pseudo variables

translate({'__CALLER__', Meta, Atom}, S) when is_atom(Atom) ->
  {{var, ?line(Meta), '__CALLER__'}, S#elixir_scope{caller=true}};

%% Functions

translate({'&', Meta, [{'/', [], [{Fun, [], Atom}, Arity]}]}, S)
    when is_atom(Fun), is_atom(Atom), is_integer(Arity) ->
  {{'fun', ?line(Meta), {function, Fun, Arity}}, S};
translate({'&', Meta, [Arg]}, S) when is_integer(Arg) ->
  compile_error(Meta, S#elixir_scope.file, "unhandled &~B outside of a capture", [Arg]);

translate({fn, Meta, Clauses}, S) ->
  elixir_fn:translate(Meta, Clauses, S);

%% Cond

translate({'cond', CondMeta, [[{do, Pairs}]]}, S) ->
  [{'->', Meta, [[Condition], Body]}|T] = lists:reverse(Pairs),
  Case =
    case Condition of
      {'_', _, Atom} when is_atom(Atom) ->
        compile_error(Meta, S#elixir_scope.file, "unbound variable _ inside cond. "
          "If you want the last clause to always match, you probably meant to use: true ->");
      X when is_atom(X) and (X /= false) and (X /= nil) ->
        build_cond_clauses(T, Body, Meta);
      _ ->
        {Truthy, Other} = build_truthy_clause(Meta, Condition, Body),
        Error = {{'.', Meta, [erlang, error]}, [], [cond_clause]},
        Falsy = {'->', Meta, [[Other], Error]},
        Acc = {'case', Meta, [Condition, [{do, [Truthy, Falsy]}]]},
        build_cond_clauses(T, Acc, Meta)
    end,
  translate(replace_case_meta(CondMeta, Case), S);

%% Case

translate({'case', Meta, [Expr, KV]}, S) ->
  Clauses = elixir_clauses:get_pairs(do, KV, match),
  {TExpr, NS} = translate(Expr, S),
  {TClauses, TS} = elixir_clauses:clauses(Meta, Clauses, NS),
  {{'case', ?line(Meta), TExpr, TClauses}, TS};

%% Try

translate({'try', Meta, [Clauses]}, RS) ->
  S  = RS#elixir_scope{noname=true},
  Do = proplists:get_value('do', Clauses, nil),
  {TDo, SB} = elixir_translator:translate(Do, S),

  Catch = [Tuple || {X, _} = Tuple <- Clauses, X == 'rescue' orelse X == 'catch'],
  {TCatch, SC} = elixir_try:clauses(Meta, Catch, mergec(S, SB)),

  case lists:keyfind('after', 1, Clauses) of
    {'after', After} ->
      {TBlock, SA} = translate(After, mergec(S, SC)),
      TAfter = unblock(TBlock);
    false ->
      {TAfter, SA} = {[], mergec(S, SC)}
  end,

  Else = elixir_clauses:get_pairs(else, Clauses, match),
  {TElse, SE} = elixir_clauses:clauses(Meta, Else, mergec(S, SA)),

  SF = (mergec(S, SE))#elixir_scope{noname=RS#elixir_scope.noname},
  {{'try', ?line(Meta), unblock(TDo), TElse, TCatch, TAfter}, SF};

%% Receive

translate({'receive', Meta, [KV]}, S) ->
  Do = elixir_clauses:get_pairs(do, KV, match, true),

  case lists:keyfind('after', 1, KV) of
    false ->
      {TClauses, SC} = elixir_clauses:clauses(Meta, Do, S),
      {{'receive', ?line(Meta), TClauses}, SC};
    _ ->
      After = elixir_clauses:get_pairs('after', KV, expr),
      {TClauses, SC} = elixir_clauses:clauses(Meta, Do ++ After, S),
      {FClauses, TAfter} = elixir_utils:split_last(TClauses),
      {_, _, [FExpr], _, FAfter} = TAfter,
      {{'receive', ?line(Meta), FClauses, FExpr, FAfter}, SC}
  end;

%% Comprehensions

translate({for, Meta, [_|_] = Args}, S) ->
  elixir_for:translate(Meta, Args, true, S);

%% Super

translate({super, Meta, Args}, S) when is_list(Args) ->
  Module = assert_module_scope(Meta, super, S),
  Function = assert_function_scope(Meta, super, S),
  elixir_def_overridable:ensure_defined(Meta, Module, Function, S),

  {_, Arity} = Function,

  {TArgs, TS} = if
    length(Args) == Arity ->
      translate_args(Args, S);
    true ->
      compile_error(Meta, S#elixir_scope.file, "super must be called with the same number of "
                    "arguments as the current function")
  end,

  Super = elixir_def_overridable:name(Module, Function),
  {{call, ?line(Meta), {atom, ?line(Meta), Super}, TArgs}, TS#elixir_scope{super=true}};

%% Variables

translate({'^', Meta, [{Name, VarMeta, Kind}]}, #elixir_scope{context=match} = S) when is_atom(Name), is_atom(Kind) ->
  Tuple = {Name, var_kind(VarMeta, Kind)},
  case orddict:find(Tuple, S#elixir_scope.backup_vars) of
    {ok, {Value, _Counter}} ->
      {{var, ?line(Meta), Value}, S};
    error ->
      compile_error(Meta, S#elixir_scope.file, "unbound variable ^~ts", [Name])
  end;

translate({'_', Meta, Kind}, #elixir_scope{context=match} = S) when is_atom(Kind) ->
  {{var, ?line(Meta), '_'}, S};

translate({'_', Meta, Kind}, S) when is_atom(Kind) ->
  compile_error(Meta, S#elixir_scope.file, "unbound variable _");

translate({Name, Meta, Kind}, #elixir_scope{extra=map_key} = S) when is_atom(Name), is_atom(Kind) ->
  compile_error(Meta, S#elixir_scope.file, "illegal use of variable ~ts in map key", [Name]);

translate({Name, Meta, Kind}, S) when is_atom(Name), is_atom(Kind) ->
  elixir_scope:translate_var(Meta, Name, var_kind(Meta, Kind), S);

%% Local calls

translate({Name, Meta, Args}, S) when is_atom(Name), is_list(Meta), is_list(Args) ->
  if
    S#elixir_scope.context == match ->
      compile_error(Meta, S#elixir_scope.file,
                    "cannot invoke local ~ts/~B inside match", [Name, length(Args)]);
    S#elixir_scope.context == guard ->
      Arity = length(Args),
      File  = S#elixir_scope.file,
      case Arity of
        0 -> compile_error(Meta, File, "unknown variable ~ts or cannot invoke "
                           "local ~ts/~B inside guard", [Name, Name, Arity]);
        _ -> compile_error(Meta, File, "cannot invoke local ~ts/~B inside guard",
                           [Name, Arity])
      end;
    true ->
      Line = ?line(Meta),
      {TArgs, NS} = translate_args(Args, S),
      {{call, Line, {atom, Line, Name}, TArgs}, NS}
  end;

%% Remote calls

translate({{'.', _, [Left, Right]}, Meta, []}, S)
    when is_tuple(Left), is_atom(Right), is_list(Meta) ->
  assert_allowed_in_context(Meta, Left, Right, 0, S),

  {TLeft, SL}  = translate(Left, S),
  {Var, _, SV} = elixir_scope:build_var('_', SL),

  Line   = ?line(Meta),
  TRight = {atom, Line, Right},

  %% TODO: Consider making this {badkey, _} error
  TVar = {var, Line, Var},
  TMap = {map, Line, [
    {map_field_assoc, Line,
      {atom, Line, '__struct__'},
      {atom, Line, 'Elixir.KeyError'}},
    {map_field_assoc, Line,
      {atom, Line, '__exception__'},
      {atom, Line, 'true'}},
    {map_field_assoc, Line,
      {atom, Line, key},
      TRight},
    {map_field_assoc, Line,
      {atom, Line, term},
      TVar}]},

  %% TODO: There is a bug in dialyzer that makes it fail on
  %% empty maps. We work around the bug below by using
  %% the is_map/1 guard instead of matching on map. Hopefully
  %% we can use a match on 17.1.
  %%
  %% http://erlang.org/pipermail/erlang-bugs/2014-April/004338.html
  {{'case', -1, TLeft, [
    {clause, -1,
      [{map, Line, [{map_field_exact, Line, TRight, TVar}]}],
      [],
      [TVar]},
    {clause, -1,
      [TVar],
      [[elixir_utils:erl_call(Line, erlang, is_map, [TVar])]],
      [elixir_utils:erl_call(Line, erlang, error, [TMap])]},
    {clause, -1,
      [TVar],
      [],
      [{call, Line, {remote, Line, TVar, TRight}, []}]}
  ]}, SV};

translate({{'.', _, [Left, Right]}, Meta, Args}, S)
    when (is_tuple(Left) orelse is_atom(Left)), is_atom(Right), is_list(Meta), is_list(Args) ->
  {TLeft, SL} = translate(Left, S),
  {TArgs, SA} = translate_args(Args, mergec(S, SL)),

  Line   = ?line(Meta),
  Arity  = length(Args),
  TRight = {atom, Line, Right},
  SC = mergev(SL, SA),

  %% Rewrite erlang function calls as operators so they
  %% work on guards, matches and so on.
  case (Left == erlang) andalso guard_op(Right, Arity) of
    true ->
      case TArgs of
        [TOne]       -> {{op, Line, Right, TOne}, SC};
        [TOne, TTwo] -> {{op, Line, Right, TOne, TTwo}, SC}
      end;
    false ->
      assert_allowed_in_context(Meta, Left, Right, Arity, S),
      {{call, Line, {remote, Line, TLeft, TRight}, TArgs}, SC}
  end;

%% Anonymous function calls

translate({{'.', _, [Expr]}, Meta, Args}, S) when is_list(Args) ->
  {TExpr, SE} = translate(Expr, S),
  {TArgs, SA} = translate_args(Args, mergec(S, SE)),
  {{call, ?line(Meta), TExpr, TArgs}, mergev(SE, SA)};

%% Literals

translate(List, S) when is_list(List) ->
  Fun = case S#elixir_scope.context of
    match -> fun translate/2;
    _     -> fun(X, Acc) -> translate_arg(X, Acc, S) end
  end,
  translate_list(List, Fun, S, []);

translate({Left, Right}, S) ->
  {TArgs, SE} = translate_args([Left, Right], S),
  {{tuple, 0, TArgs}, SE};

translate(Other, S) ->
  {elixir_utils:elixir_to_erl(Other), S}.

%% Helpers

guard_op(Op, Arity) ->
  try erl_internal:op_type(Op, Arity) of
    arith -> true;
    list  -> true;
    comp  -> true;
    bool  -> true;
    send  -> false
  catch
    _:_ -> false
  end.

translate_list([{'|', _, [_, _]=Args}], Fun, Acc, List) ->
  {[TLeft, TRight], TAcc} = lists:mapfoldl(Fun, Acc, Args),
  {build_list([TLeft|List], TRight), TAcc};
translate_list([H|T], Fun, Acc, List) ->
  {TH, TAcc} = Fun(H, Acc),
  translate_list(T, Fun, TAcc, [TH|List]);
translate_list([], _Fun, Acc, List) ->
  {build_list(List, {nil, 0}), Acc}.

build_list([H|T], Acc) ->
  build_list(T, {cons, 0, H, Acc});
build_list([], Acc) ->
  Acc.

var_kind(Meta, Kind) ->
  case lists:keyfind(counter, 1, Meta) of
    {counter, Counter} -> Counter;
    false -> Kind
  end.

%% Pack a list of expressions from a block.
unblock({'block', _, Exprs}) -> Exprs;
unblock(Expr)                -> [Expr].

%% Translate args

translate_arg(Arg, Acc, S) when is_number(Arg); is_atom(Arg); is_binary(Arg); is_pid(Arg); is_function(Arg) ->
  {TArg, _} = translate(Arg, S),
  {TArg, Acc};
translate_arg(Arg, Acc, S) ->
  {TArg, TAcc} = translate(Arg, mergec(S, Acc)),
  {TArg, mergev(Acc, TAcc)}.

translate_args(Args, #elixir_scope{context=match} = S) ->
  lists:mapfoldl(fun translate/2, S, Args);

translate_args(Args, S) ->
  lists:mapfoldl(fun(X, Acc) -> translate_arg(X, Acc, S) end, S, Args).

%% Translate blocks

translate_block([], Acc, S) ->
  {lists:reverse(Acc), S};
translate_block([H], Acc, S) ->
  {TH, TS} = translate(H, S),
  translate_block([], [TH|Acc], TS);
translate_block([{for, Meta, [_|_] = Args}|T], Acc, S) ->
  {TH, TS} = elixir_for:translate(Meta, Args, false, S),
  translate_block(T, [TH|Acc], TS);
translate_block([{'=', _, [{'_', _, Ctx}, {for, Meta, [_|_] = Args}]}|T], Acc, S) when is_atom(Ctx) ->
  {TH, TS} = elixir_for:translate(Meta, Args, false, S),
  translate_block(T, [TH|Acc], TS);
translate_block([H|T], Acc, S) ->
  {TH, TS} = translate(H, S),
  translate_block(T, [TH|Acc], TS).

%% Cond

build_cond_clauses([{'->', NewMeta, [[Condition], Body]}|T], Acc, OldMeta) ->
  {Truthy, Other} = build_truthy_clause(NewMeta, Condition, Body),
  Falsy = {'->', OldMeta, [[Other], Acc]},
  Case = {'case', NewMeta, [Condition, [{do, [Truthy, Falsy]}]]},
  build_cond_clauses(T, Case, NewMeta);
build_cond_clauses([], Acc, _) ->
  Acc.

replace_case_meta(Meta, {'case', _, Args}) ->
  {'case', Meta, Args};
replace_case_meta(_Meta, Other) ->
  Other.

build_truthy_clause(Meta, Condition, Body) ->
  case elixir_utils:returns_boolean(Condition) of
    true ->
      {{'->', Meta, [[true], Body]}, false};
    false ->
      Var  = {'cond', [], 'Elixir'},
      Head = {'when', [], [Var,
        {{'.', [], [erlang, 'andalso']}, [], [
          {{'.', [], [erlang, '/=']}, [], [Var, nil]},
          {{'.', [], [erlang, '/=']}, [], [Var, false]}
        ]}
      ]},
      {{'->', Meta, [[Head], Body]}, {'_', [], nil}}
  end.

%% Assertions

assert_module_scope(Meta, Kind, #elixir_scope{module=nil, file=File}) ->
  compile_error(Meta, File, "cannot invoke ~ts outside module", [Kind]);
assert_module_scope(_Meta, _Kind, #elixir_scope{module=Module}) -> Module.

assert_function_scope(Meta, Kind, #elixir_scope{function=nil, file=File}) ->
  compile_error(Meta, File, "cannot invoke ~ts outside function", [Kind]);
assert_function_scope(_Meta, _Kind, #elixir_scope{function=Function}) -> Function.

assert_allowed_in_context(Meta, Left, Right, Arity, #elixir_scope{context=Context} = S)
    when (Context == match) orelse (Context == guard) ->
  case (Left == erlang) andalso erl_internal:guard_bif(Right, Arity) of
    true  -> ok;
    false ->
      compile_error(Meta, S#elixir_scope.file, "cannot invoke remote function ~ts.~ts/~B inside ~ts",
        ['Elixir.Macro':to_string(Left), Right, Arity, Context])
  end;
assert_allowed_in_context(_, _, _, _, _) ->
  ok.
