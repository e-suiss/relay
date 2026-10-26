defmodule RelayDev.Credo.LaneOutsideLane do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check:
        "Only `Relay.Platform.Lane.of/1` maps a message class to a lane (INV-16, T-31); a clause that matches a class and yields a lane re-derives it."
    ]

  @message "only Relay.Platform.Lane.of/1 derives a lane from a message class (INV-16, T-31)"
  @classes [
    :security,
    :transactional,
    :action_required,
    :operational,
    :system,
    :social,
    :marketing
  ]
  @lanes [:l0, :l1, :l2, :l3, "l0", "l1", "l2", "l3"]

  # INV-16
  # T-31
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk(&1, &2), ctx).issues
  end

  defp walk({:->, meta, [patterns, body]} = ast, ctx), do: {ast, check(patterns, body, meta, ctx)}

  defp walk({kind, meta, [{_name, _, args}, [{:do, body} | _]]} = ast, ctx)
       when kind in [:def, :defp] and is_list(args),
       do: {ast, check(args, body, meta, ctx)}

  defp walk(ast, ctx), do: {ast, ctx}

  defp check(patterns, body, meta, ctx) do
    if mentions?(patterns, @classes) and mentions?(body, @lanes),
      do:
        put_issue(ctx, format_issue(ctx, message: @message, line_no: meta[:line], trigger: "->")),
      else: ctx
  end

  defp mentions?(ast, values) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        node, false -> {node, node in values}
      end)

    found
  end
end
