defmodule RelayDev.Credo.EtsTables do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      An ETS table is named by a literal atom, `__MODULE__` or a module attribute and is created once by its owner. A table name computed at run time means a table per tenant or per entity, which T-45 (5) forbids: shared read-heavy data lives in one table keyed by tenant.
      """
    ]

  @message "name ETS tables with a literal atom; no table per tenant or entity (T-45 (5))"

  # T-45 (5)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    RelayDev.Credo.ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {:ets, :new, [name, _opts]} -> if literal?(name), do: nil, else: @message
        _ -> nil
      end
    ])
  end

  defp literal?(name) when is_atom(name), do: true
  defp literal?({:__MODULE__, _, _}), do: true
  defp literal?({:@, _, [{attribute, _, _}]}) when is_atom(attribute), do: true
  defp literal?(_name), do: false
end
