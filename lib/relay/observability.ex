defmodule Relay.Observability do
  @moduledoc """
  The observability context: the SLO table, the performance budgets, the bounded tenant label of counters, the noisy neighbour shares and the VM system monitor. Other contexts emit `[:relay, ...]` telemetry events; this context turns the platform's own events (requests, jobs, breaker transitions, VM samples) into the events the metric definitions of `RelayWeb.Telemetry` export, and never reads tenant content.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform], exports: [Slo, Budget]

  alias Relay.Observability.Handlers
  alias Relay.Observability.TopTenants
  alias Relay.Observability.VmMonitor

  # OP-32
  # OP-35
  # T-48
  # TN-62
  @doc "The supervised children of the context: the tenant label window and the VM system monitor."
  @spec children() :: [Supervisor.child_spec()]
  def children, do: [TopTenants, VmMonitor]

  # T-48
  # T-53 (2)
  @doc "Emits one periodic VM sample; the telemetry poller calls it."
  @spec vm_sample() :: :ok
  def vm_sample, do: VmMonitor.sample()

  # OP-35 (3)
  @doc "The tenant label of a counter: the tenant's identifier while it is among the busiest tenants, otherwise `other`."
  @spec tenant_label(String.t() | nil) :: String.t()
  def tenant_label(tenant), do: TopTenants.label(tenant)

  # OP-36
  # T-68 (3)
  # TN-62
  @doc "Attaches the handlers that derive SLI, budget, job and breaker events; idempotent."
  @spec attach() :: :ok
  def attach, do: Handlers.attach()
end
