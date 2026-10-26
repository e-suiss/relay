defmodule RelayDev.Credo.VirtualOffset do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check:
        "The virtual clock offset of the `test` plane is read only through `Relay.Clock.Virtual`; business time comes from `Relay.Clock.business_now/1` (TN-8, X-27)."
    ]

  alias Credo.Check.Context
  alias Credo.Code

  @message "read business time through Relay.Clock.business_now/1, not the virtual offset (TN-8, X-27)"
  @sql ~r/\bvirtual_clock_get\b|\brelay\.virtual_clocks\b/

  # TN-8
  # X-27
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    ctx = Code.prewalk(source_file, &walk/2, ctx)

    source_file
    |> SourceFile.lines()
    |> Enum.reduce(ctx, fn {line_no, line}, acc ->
      case Regex.run(@sql, line) do
        [trigger | _] -> issue(acc, trigger, line: line_no)
        nil -> acc
      end
    end)
    |> Map.fetch!(:issues)
  end

  defp walk({:__aliases__, meta, [:Relay, :Clock, :VirtualStore]} = ast, ctx),
    do: {ast, issue(ctx, "Relay.Clock.VirtualStore", meta)}

  defp walk(
         {{:., meta, [{:__aliases__, _, [:Relay, :Clock, :Virtual]}, :offset_ms]}, _, _} = ast,
         ctx
       ),
       do: {ast, issue(ctx, "Relay.Clock.Virtual.offset_ms", meta)}

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue(ctx, trigger, meta),
    do:
      Context.put_issue(
        ctx,
        format_issue(ctx, message: @message, trigger: trigger, line_no: meta[:line])
      )
end
