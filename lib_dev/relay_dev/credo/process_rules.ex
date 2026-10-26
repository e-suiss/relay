defmodule RelayDev.Credo.ProcessRules do
  @moduledoc """
  Shared walker for the process and memory checks of T-45. A rule is a function that receives a remote call as `{module, function, args}` (`module` is an Elixir alias or an Erlang atom) and returns a message for a forbidden call or nil.
  """

  alias Credo.Check.Context
  alias Credo.Code
  alias Credo.SourceFile

  @type call :: {module() | atom(), atom(), [Macro.t()]}
  @type rule :: (call() -> String.t() | nil)

  @doc "Returns issues for the calls in `source_file` that a rule rejects."
  @spec issues(SourceFile.t(), keyword(), module(), [rule()]) :: [Credo.Issue.t()]
  def issues(%SourceFile{} = source_file, params, check, rules) do
    ctx = Context.build(source_file, params, check)
    Code.prewalk(source_file, &walk(&1, &2, rules, check), ctx).issues
  end

  defp walk({{:., _, [target, fun]}, meta, args} = ast, ctx, rules, check)
       when is_atom(fun) and is_list(args) do
    call = {module(target), fun, args}

    ctx =
      Enum.reduce(rules, ctx, fn rule, acc ->
        case rule.(call) do
          nil ->
            acc

          message ->
            issue =
              check.format_issue(acc,
                message: message,
                trigger: "#{inspect(elem(call, 0))}.#{fun}",
                line_no: meta[:line]
              )

            Context.put_issue(acc, issue)
        end
      end)

    {ast, ctx}
  end

  defp walk(ast, ctx, _rules, _check), do: {ast, ctx}

  defp module({:__aliases__, _, parts}) when is_list(parts) do
    Module.safe_concat(parts)
  rescue
    ArgumentError -> :unknown
  end

  defp module(atom) when is_atom(atom), do: atom
  defp module(_), do: :unknown

  @doc "Returns true if the keyword list literal `opts` has every key in `keys`."
  @spec keys?(Macro.t(), [atom()]) :: boolean()
  def keys?(opts, keys) when is_list(opts),
    do: Enum.all?(keys, fn key -> Enum.any?(opts, &match?({^key, _}, &1)) end)

  def keys?(_opts, _keys), do: false
end
