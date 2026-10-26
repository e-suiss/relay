defmodule RelayDev.Credo.TenantProcesses do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      A stateful per-tenant component (an APNs connection, a tenant × provider breaker) starts lazily and stops itself when idle (T-45 (6)). Dynamic children are therefore started only through `Relay.TenantWorker.ensure/3`, which starts on first use and gives every worker an idle timeout; stateless workers are shared.
      """
    ]

  @message "start per-tenant processes through Relay.TenantWorker (lazy, idle-terminating) (T-45 (6))"

  # T-45 (6)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    RelayDev.Credo.ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {DynamicSupervisor, :start_child, _args} -> @message
        _ -> nil
      end
    ])
  end
end
