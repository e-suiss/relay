defmodule RelayDev.Credo.MjmlOnSendPath do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      MJML is compiled only when a template version is published (TP-8, T-98). The send path modules listed in `.credo.exs` never reference `Relay.Templates.Mjml`; they render the HTML compiled at publish time.
      """
    ]

  alias Credo.Check.Context

  @message "MJML is compiled only at publish time, never on the send path (TP-8, T-98)"
  @names [[:Relay, :Templates, :Mjml], [:Templates, :Mjml], [:Mjml]]

  # TP-8
  # T-98
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({:__aliases__, meta, parts} = ast, ctx) when parts in @names do
    issue =
      format_issue(ctx, message: @message, trigger: Enum.join(parts, "."), line_no: meta[:line])

    {ast, Context.put_issue(ctx, issue)}
  end

  defp walk(ast, ctx), do: {ast, ctx}
end
