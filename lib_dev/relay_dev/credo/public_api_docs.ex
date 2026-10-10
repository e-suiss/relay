defmodule RelayDev.Credo.PublicApiDocs do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check:
        "Every public function of a documented module has `@doc` and `@spec`, unless it implements a callback (T-58)."
    ]

  # T-58
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({:defmodule, _, [_name, [do: body]]} = ast, ctx) do
    {ast, check_module(body_list(body), ctx)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp body_list({:__block__, _, list}), do: list
  defp body_list(single), do: [single]

  defp check_module(body, ctx) do
    if Enum.any?(body, &match?({:@, _, [{:moduledoc, _, [false]}]}, &1)) do
      ctx
    else
      body
      |> Enum.reduce({ctx, %{doc: false, spec: false, impl: false}, MapSet.new()}, &step/2)
      |> elem(0)
    end
  end

  defp step({:@, _, [{:doc, _, [value]}]}, {ctx, attrs, seen}),
    do: {ctx, %{attrs | doc: value != false or :hidden}, seen}

  defp step({:@, _, [{:spec, _, _}]}, {ctx, attrs, seen}), do: {ctx, %{attrs | spec: true}, seen}
  defp step({:@, _, [{:impl, _, _}]}, {ctx, attrs, seen}), do: {ctx, %{attrs | impl: true}, seen}

  defp step({:def, meta, [head | _]}, {ctx, attrs, seen}) do
    {name, arity} = signature(head)

    cond do
      MapSet.member?(seen, name) -> {ctx, reset(), seen}
      attrs.impl or attrs.doc == :hidden -> {ctx, reset(), MapSet.put(seen, name)}
      true -> {report(ctx, attrs, meta, "#{name}/#{arity}"), reset(), MapSet.put(seen, name)}
    end
  end

  defp step(_other, acc), do: acc

  defp reset, do: %{doc: false, spec: false, impl: false}

  defp signature({:when, _, [head | _]}), do: signature(head)
  defp signature({name, _, args}) when is_atom(name), do: {name, length(List.wrap(args))}
  defp signature(_), do: {:unknown, 0}

  defp report(ctx, attrs, meta, fun) do
    missing = Enum.reject([if(!attrs.doc, do: "@doc"), if(!attrs.spec, do: "@spec")], &is_nil/1)

    if missing == [],
      do: ctx,
      else:
        put_issue(
          ctx,
          format_issue(ctx,
            message: "#{fun} is missing #{Enum.join(missing, " and ")} (T-58)",
            line_no: meta[:line],
            trigger: fun
          )
        )
  end
end
