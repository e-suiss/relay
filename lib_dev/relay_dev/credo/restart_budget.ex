defmodule RelayDev.Credo.RestartBudget do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Every supervisor states its restart budget, `max_restarts` and `max_seconds`, where it is started (T-45 (3)). Budgets multiply down the tree, so each one is a decision: a provider outage must not walk restarts up to the top and stop the node.
      """
    ]

  alias RelayDev.Credo.ProcessRules

  @message "state the supervisor's restart budget with max_restarts and max_seconds (T-45 (3))"

  # T-45 (3)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {Supervisor, fun, [_children, opts]} when fun in [:init, :start_link] -> budget(opts)
        {DynamicSupervisor, :init, [opts]} -> budget(opts)
        _ -> nil
      end
    ])
  end

  defp budget(opts) do
    if ProcessRules.keys?(opts, [:max_restarts, :max_seconds]),
      do: nil,
      else: @message
  end
end
