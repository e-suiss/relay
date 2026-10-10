defmodule RelayDev.Credo.Calls do
  @moduledoc """
  Shared walker for checks that forbid calls. A rule is `{module, function, message}`; `module` is an Elixir alias (`DateTime`) or an Erlang module atom (`:rand`), and `function` is an atom or `:_` for any function. Local calls such as `spawn/1` use `nil` as the module.
  """

  alias Credo.Check.Context
  alias Credo.Code
  alias Credo.SourceFile

  @type rule :: {module() | atom() | nil, atom(), String.t()}

  @doc "Returns issues for forbidden calls in `source_file`."
  @spec issues(SourceFile.t(), keyword(), module(), [rule()]) :: [Credo.Issue.t()]
  def issues(%SourceFile{} = source_file, params, check, rules) do
    ctx = Context.build(source_file, params, check)
    result = Code.prewalk(source_file, &walk(&1, &2, rules, check), ctx)
    result.issues
  end

  defp walk({{:., _, [target, fun]}, meta, args} = ast, ctx, rules, check)
       when is_atom(fun) and is_list(args) do
    module = target_module(target)
    {ast, add(ctx, check, rules, module, fun, args, meta)}
  end

  defp walk({fun, meta, args} = ast, ctx, rules, check) when is_atom(fun) and is_list(args) do
    {ast, add(ctx, check, rules, nil, fun, args, meta)}
  end

  defp walk(ast, ctx, _rules, _check), do: {ast, ctx}

  defp target_module({:__aliases__, _, parts}) when is_list(parts) do
    Module.safe_concat(parts)
  rescue
    ArgumentError -> :unknown
  end

  defp target_module(atom) when is_atom(atom), do: atom
  defp target_module(_), do: :unknown

  defp add(ctx, check, rules, module, fun, args, meta) do
    Enum.reduce(rules, ctx, fn rule, acc ->
      if match?(rule, module, fun, args) do
        {_, _, message} = rule

        issue =
          check.format_issue(acc,
            message: message,
            trigger: "#{inspect_module(module)}#{fun}",
            line_no: meta[:line]
          )

        Context.put_issue(acc, issue)
      else
        acc
      end
    end)
  end

  defp match?({rule_module, rule_fun, _}, module, fun, _args) do
    rule_module == module and (rule_fun == :_ or rule_fun == fun)
  end

  defp inspect_module(nil), do: ""
  defp inspect_module(module), do: inspect(module) <> "."
end
