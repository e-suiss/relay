defmodule Relay.Agents.Ceiling.Decision do
  @moduledoc """
  The agent ceiling as a pure decision (AG-48, AG-50, AG-70, INV-34). Only a notification whose sender type is `agent` is subject to it; the ceiling is apart from the frequency cap and from throttle and counts the notifications an agent sent in a rolling hour and a rolling day. The values are the contract's `agent_ceiling` limits; a tenant's own values only count when they are lower. A usage that cannot be read holds the notification: the ceiling fails closed.
  """

  @per_hour Relay.Limits.fetch!(["agent_ceiling", "per_hour"])
  @per_day Relay.Limits.fetch!(["agent_ceiling", "per_day"])

  @exceeded "agent_ceiling.exceeded"
  @unreadable "agent_ceiling.counter_unreadable"

  @type limits :: %{per_hour: pos_integer(), per_day: pos_integer()}
  @type usage :: %{hour: non_neg_integer(), day: non_neg_integer()} | :unreadable
  @type t :: :pass | {:hold, String.t()}

  # AG-70
  @doc "The ceiling in force: the contract's values, each lowered to the tenant's own value when that is a positive integer below it."
  @spec limits(term(), term()) :: limits()
  def limits(tenant_hour, tenant_day),
    do: %{per_hour: lower(tenant_hour, @per_hour), per_day: lower(tenant_day, @per_day)}

  defp lower(value, default) when is_integer(value) and value >= 1, do: min(value, default)
  defp lower(_value, default), do: default

  # AG-48
  # C-24
  @doc "Returns true if a notification of `sender_type` is subject to the agent ceiling."
  @spec subject?(term()) :: boolean()
  def subject?(sender_type), do: sender_type in ["agent", :agent]

  # AG-48
  # AG-50
  # INV-34
  @doc "Decides one notification from the agent's usage: `:pass` below both limits, otherwise `{:hold, rule_id}`; an unreadable usage holds."
  @spec decide(usage(), limits()) :: t()
  def decide(:unreadable, _limits), do: {:hold, @unreadable}

  def decide(%{hour: hour, day: day}, %{per_hour: per_hour, per_day: per_day}) do
    if hour >= per_hour or day >= per_day, do: {:hold, @exceeded}, else: :pass
  end
end
