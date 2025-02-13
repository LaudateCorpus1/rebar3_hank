%%% @doc Utility functions
-module(hank_utils).

%% Allow erl_syntax:syntaxTree/0 type spec
-elvis([{elvis_style, atom_naming_convention, #{regex => "^([a-zA-Z][a-z0-9]*_?)*$"}}]).

-export([macro_arity/1, macro_name/1, macro_definition_name/1, function_name/1,
         function_tuple/1, function_description/1, application_node_to_mfa/1,
         macro_from_control_flow_attr/1, attr_name/1, node_has_attrs/2, attr_args_concrete/2,
         is_old_test_suite/1, node_line/1, paths_match/2, format_text/2, node_has_atom/2]).

%% @doc Get the macro arity of given Node
-spec macro_arity(erl_syntax:syntaxTree()) -> none | pos_integer().
macro_arity(Node) ->
    case erl_syntax:macro_arguments(Node) of
        none ->
            none;
        Args ->
            length(Args)
    end.

%% @doc Get the parsed macro name of given Node
-spec macro_name(erl_syntax:syntaxTree()) -> string().
macro_name(Node) ->
    parse_node_name(erl_syntax:macro_name(Node)).

%% @doc Parse the given Node name
-spec parse_node_name(erl_syntax:syntaxTree()) -> unknown | string().
parse_node_name(Node) ->
    case erl_syntax:type(Node) of
        variable ->
            erl_syntax:variable_literal(Node);
        atom ->
            erl_syntax:atom_name(Node);
        macro ->
            parse_node_name(erl_syntax:macro_name(Node));
        _Other ->
            % Probably a case, a record field or some other block of code
            unknown
    end.

%% @doc Get the macro definition name and arity of a given Macro Node.
-spec macro_definition_name(erl_syntax:syntaxTree()) -> {string(), integer() | atom()}.
macro_definition_name(Node) ->
    [MacroNameNode | _] = erl_syntax:attribute_arguments(Node),
    case erl_syntax:type(MacroNameNode) of
        application ->
            Operator = erl_syntax:application_operator(MacroNameNode),
            MacroName = parse_node_name(Operator),
            MacroArity = length(erl_syntax:application_arguments(MacroNameNode)),
            {MacroName, MacroArity};
        variable ->
            {erl_syntax:variable_literal(MacroNameNode), none};
        atom ->
            {erl_syntax:atom_literal(MacroNameNode), none}
    end.

%% @doc Get the function name of a given Function Node.
-spec function_name(erl_syntax:syntaxTree()) -> string().
function_name(Node) ->
    FuncNameNode = erl_syntax:function_name(Node),
    case erl_syntax:type(FuncNameNode) of
        macro ->
            [$? | macro_name(FuncNameNode)];
        atom ->
            erl_syntax:atom_name(FuncNameNode)
    end.

%% @doc Get the function definition tuple {name, arity} of a given Function Node.
-spec function_tuple(erl_syntax:syntaxTree()) -> {atom(), pos_integer()}.
function_tuple(Node) ->
    {erlang:list_to_atom(function_name(Node)), erl_syntax:function_arity(Node)}.

%% @doc Get the function definition name and arity of a given Function Node.
-spec function_description(erl_syntax:syntaxTree()) -> string().
function_description(Node) ->
    FuncName = function_name(Node),
    FuncArity = erl_syntax:function_arity(Node),
    FuncName ++ [$/ | integer_to_list(FuncArity)].

%% @doc Returns a MFA tuple for given application node
-spec application_node_to_mfa(erl_syntax:syntaxTree()) ->
                                 undefined |
                                 {unknown | string(),
                                  unknown | string(),
                                  [erl_syntax:syntaxTree()]} |
                                 {string(), [erl_syntax:syntaxTree()]}.
application_node_to_mfa(Node) ->
    case erl_syntax:type(Node) of
        application ->
            Operator = erl_syntax:application_operator(Node),
            case erl_syntax:type(Operator) of
                module_qualifier ->
                    Module = erl_syntax:module_qualifier_argument(Operator),
                    Function = erl_syntax:module_qualifier_body(Operator),
                    {parse_node_name(Module),
                     parse_node_name(Function),
                     erl_syntax:application_arguments(Node)};
                atom ->
                    {erl_syntax:atom_name(Operator), erl_syntax:application_arguments(Node)};
                variable ->
                    {erl_syntax:variable_literal(Operator), erl_syntax:application_arguments(Node)};
                _ ->
                    undefined
            end;
        _ ->
            undefined
    end.

%% @doc Generates a macro from the variable that's used in a control flow attribute.
%%      e.g. returns ?MACRO if it receives -ifdef(MACRO).
-spec macro_from_control_flow_attr(erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
macro_from_control_flow_attr(Node) ->
    [MacroName | _] = erl_syntax:attribute_arguments(Node),
    erl_syntax:macro(MacroName).

%% @doc Macro dodging version of erl_syntax:attribute_name/1
-spec attr_name(erl_syntax:syntaxTree()) -> atom().
attr_name(Node) ->
    N = erl_syntax:attribute_name(Node),
    try
        erl_syntax:concrete(N)
    catch
        _:_ ->
            N
    end.

%% @doc Whether the given Node node
%%      has defined the given AttrNames attribute names or not
-spec node_has_attrs(erl_syntax:syntaxTree(), atom() | [atom()]) -> boolean().
node_has_attrs(Node, AttrName) when not is_list(AttrName) ->
    node_has_attrs(Node, [AttrName]);
node_has_attrs(Node, AttrNames) ->
    erl_syntax:type(Node) == attribute andalso lists:member(attr_name(Node), AttrNames).

%% @doc Extract attribute arguments from given AST nodes list
%%      whose attribute name is AttrName and apply MapFunc to every element
-spec attr_args(erl_syntax:forms(), atom() | [atom()], function()) -> [term()].
attr_args(AST, AttrName, MapFunc) when not is_list(AttrName) ->
    attr_args(AST, [AttrName], MapFunc);
attr_args(AST, AttrNames, MapFunc) ->
    [MapFunc(AttrArg)
     || Node <- AST,
        node_has_attrs(Node, AttrNames),
        AttrArg <- erl_syntax:attribute_arguments(Node)].

%% @doc Same as attr_args/3 but calling erl_syntax:concrete/1 for each element
-spec attr_args_concrete(erl_syntax:forms(), atom() | [atom()]) -> [term()].
attr_args_concrete(AST, AttrName) ->
    attr_args(AST, AttrName, fun erl_syntax:concrete/1).

%% @doc Before OTP 23.2 test suites implemented an _implicit_ behavior.
%%      The only way to figure out that a module was actually a test suite was
%%      by its name.
-spec is_old_test_suite(file:filename()) -> boolean().
is_old_test_suite(File) ->
    code:which(ct_suite) == non_existing % OTP < 23.2
    andalso re:run(File, "_SUITE.erl$") /= nomatch.

%% @doc Returns the line number of the given node
-spec node_line(erl_syntax:syntaxTree()) -> non_neg_integer().
node_line(Node) ->
    erl_anno:location(
        erl_syntax:get_pos(Node)).

%% @doc Returns all the atoms found the given node list.
-spec node_atoms([erl_syntax:syntaxTree()]) -> [atom()].
node_atoms(Nodes) ->
    FoldFun =
        fun(Node, Atoms) ->
           case erl_syntax:type(Node) of
               atom ->
                   [Node | Atoms];
               macro ->
                   MacroName = erl_syntax:macro_name(Node),
                   case erl_syntax:type(MacroName) of
                       atom ->
                           %% Note that erl_syntax_lib:fold/3 works in a DFS manner.
                           %% That's why our macro-skipping trick works:
                           %%   it removes the atom that was previously introduced
                           %%   into the accumulator.
                           Atoms -- [MacroName];
                       _ ->
                           Atoms
                   end;
               _ ->
                   Atoms
           end
        end,
    AtomNodes = erl_syntax_lib:fold(FoldFun, [], erl_syntax:form_list(Nodes)),
    lists:usort(
        lists:map(fun erl_syntax:atom_value/1, AtomNodes)).

%% @doc Whether one of the given paths is contained inside the other one or not.
%%      It doesn't matter which one is contained at which other.
%%      Verifies if FilePath and IncludePath refer both to the same file.
%%      Note that we can't just compare both filename:absname's here, since we
%%      don't really know what is the absolute path of the file referred by
%%      the include directive.
-spec paths_match(string(), string()) -> boolean().
paths_match(IncludePath, IncludePath) ->
    % The path used in the include directive is exactly the file path
    true;
paths_match(FilePath, IncludePath) ->
    % We remove relative paths because FilePath will not be a relative path and,
    % in any case, the paths will be relative to something that we don't know.
    %
    % Note that this might result in some false negatives.
    % For instance, Hank may think that lib/app1/include/header.hrl is used
    % if lib/app2/src/module.erl contains -include("header.hrl").
    % when, in reality, module is including lib/app2/include/header.erl
    % That should be an extremely edge scenario and Hank never promised to find
    % ALL the dead code, anyway. It just promised that *if* it finds something,
    % that's dead code, 100% sure.
    compare_paths(clean_path(FilePath), clean_path(IncludePath)).

%% @doc Whether one of the given paths is contained inside the other one or not
%%      It doesn't matter which one is contained at which other
compare_paths({PathA, LenA}, {PathB, LenB}) when LenA > LenB ->
    PathB == string:find(PathA, PathB, trailing);
compare_paths({PathA, _}, {PathB, _}) ->
    PathA == string:find(PathB, PathA, trailing);
compare_paths(PathA, PathB) ->
    compare_paths({PathA, length(PathA)}, {PathB, length(PathB)}).

%% @doc Removes "../" and "./" from a given Path
clean_path(Path) ->
    unicode:characters_to_list(
        string:replace(
            string:replace(Path, "../", "", all), "./", "", all)).

%% @doc Format rule result text for console output
-spec format_text(string(), list()) -> binary().
format_text(Text, Args) ->
    Formatted = io_lib:format(Text, Args),
    unicode:characters_to_binary(Formatted).

%% @doc Returns true if the node contains the atom.
%%      Only analyzes functions and attributes.
-spec node_has_atom(erl_syntax:syntaxTree(), atom()) -> boolean().
node_has_atom(Node, Atom) ->
    ToCheck =
        case erl_syntax:type(Node) of
            function ->
                [Body
                 || Clause <- erl_syntax:function_clauses(Node),
                    Body <- erl_syntax:clause_body(Clause)];
            attribute ->
                case attr_name(Node) of
                    Name when Name == record; Name == define ->
                        [_RecOrMacroName | Attrs] = erl_syntax:attribute_arguments(Node),
                        Attrs;
                    _ ->
                        []
                end;
            _ ->
                []
        end,
    lists:member(Atom, node_atoms(ToCheck)).
