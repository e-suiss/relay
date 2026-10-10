defmodule RelayDev.Credo.UnsafeConversion do
  @moduledoc false

  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check:
        "Tenant and external data never reach evaluation, atom creation or unsafe term decoding (TP-3, DS-40, OP-34)."
    ]

  @message "unsafe conversion of external data is a security incident (TP-3, DS-40, OP-34)"

  @rules [
    {EEx, :_, @message},
    {Code, :eval_string, @message},
    {Code, :eval_quoted, @message},
    {Code, :eval_file, @message},
    {Code, :eval_quoted_with_env, @message},
    {Code, :string_to_quoted, @message},
    {Code, :string_to_quoted!, @message},
    {String, :to_atom, @message},
    {List, :to_atom, @message},
    {:erlang, :binary_to_atom, @message},
    {:erlang, :list_to_atom, @message},
    {:erlang, :binary_to_term, @message}
  ]

  # TP-3
  # DS-40
  # OP-34
  @impl true
  def run(%SourceFile{} = source_file, params) do
    calls = RelayDev.Credo.Calls.issues(source_file, params, __MODULE__, @rules)
    calls ++ atom_keys(source_file, params)
  end

  defp atom_keys(source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)

    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({:keys, value} = ast, ctx) when value in [:atoms, :atoms!] do
    {ast,
     put_issue(
       ctx,
       format_issue(ctx, message: "JSON decoding with keys: :atoms (TP-3)", trigger: "keys:")
     )}
  end

  defp walk(ast, ctx), do: {ast, ctx}
end
