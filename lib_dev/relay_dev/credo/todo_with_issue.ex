defmodule RelayDev.Credo.TodoWithIssue do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [check: "A TODO names its issue: `# TODO(#123): ...` (T-58)."]

  @marker ~r/\b(TODO|FIXME|XXX|HACK)\b/
  @valid ~r/^#\s*TODO\(#\d+\):\s+\S/

  # T-58
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)

    case Code.string_to_quoted_with_comments(SourceFile.source(source_file), emit_warnings: false) do
      {:ok, _ast, comments} -> Enum.reduce(comments, ctx, &check_comment/2).issues
      {:error, _} -> []
    end
  end

  defp check_comment(%{line: line, text: text}, ctx) do
    if Regex.match?(@marker, text) and not Regex.match?(@valid, text) do
      put_issue(
        ctx,
        format_issue(ctx,
          message: "TODO must reference an issue: TODO(#n): (T-58)",
          line_no: line,
          trigger: "TODO"
        )
      )
    else
      ctx
    end
  end
end
