defmodule Relay.Platform.Fairness.Drr do
  @moduledoc """
  Deficit round robin over the tenants of a bulk lane, as a pure function. The database function `relay_ops.drr_take` runs the same round on the wait table; this module holds its constants and a reference model the rule tests run against.

  One round visits the active tenants in `(last_served_round, key)` order. Each visited tenant's deficit grows by `weight × quantum`; its due jobs are taken in `(priority, scheduled_at, id)` order while the head job's cost fits the deficit, and the deficit shrinks by each cost. A tenant left without due jobs ends the round with a deficit of zero, so nothing accumulates, and a tenant without any waiting job becomes inactive. The round ends at `max_jobs`; the tenants not visited keep their place for the next round. The quantum is never smaller than the largest job unit, so every visited tenant with a due job takes at least one.
  """

  @quantum 5_000
  @queued_cap 1_000_000

  @type wait :: %{
          required(:id) => term(),
          required(:cost) => pos_integer(),
          required(:priority) => 0..9,
          required(:scheduled_at) => integer(),
          optional(atom()) => term()
        }
  @type tenant :: %{
          key: term(),
          weight: 1..100,
          deficit: non_neg_integer(),
          last_served_round: non_neg_integer(),
          waits: [wait()]
        }

  # T-21 (2)
  # T-23
  @doc "The quantum: the largest job unit, a fan-out slice of 5 000 deliveries."
  @spec quantum() :: pos_integer()
  def quantum, do: @quantum

  # T-91 (1)
  # TN-54
  @doc "Default limit of waiting jobs per tenant and lane."
  @spec queued_cap() :: pos_integer()
  def queued_cap, do: @queued_cap

  # T-91 (1)
  @doc "Queue depth below which the dispatcher runs rounds: twice the lane's per-node budget times the worker nodes."
  @spec target_depth(pos_integer(), pos_integer()) :: pos_integer()
  def target_depth(budget, nodes)
      when is_integer(budget) and budget > 0 and is_integer(nodes) and nodes > 0,
      do: 2 * budget * nodes

  # T-21 (2)
  @doc "True if a job of `cost` may wait in a bulk lane: from 1 up to the quantum."
  @spec valid_cost?(term()) :: boolean()
  def valid_cost?(cost), do: is_integer(cost) and cost >= 1 and cost <= @quantum

  # T-21
  @doc """
  Runs one round at time `now` and returns the taken jobs as `{tenant_key, wait}` in the order taken, with the tenants as they leave the round. `quantum` must be at least `quantum/0`.
  """
  @spec round([tenant()], pos_integer(), integer(), pos_integer(), pos_integer()) ::
          {[{term(), wait()}], [tenant()]}
  def round(tenants, round_no, now, quantum, max_jobs)
      when is_list(tenants) and is_integer(round_no) and is_integer(now) and
             is_integer(quantum) and quantum >= @quantum and is_integer(max_jobs) and
             max_jobs >= 1 do
    {active, idle} = Enum.split_with(tenants, &(&1.waits != []))

    {visited, taken} =
      active
      |> Enum.sort_by(&{&1.last_served_round, &1.key})
      |> Enum.map_reduce([], fn tenant, taken ->
        if length(taken) >= max_jobs,
          do: {tenant, taken},
          else: serve(tenant, taken, round_no, now, quantum, max_jobs)
      end)

    {Enum.reverse(taken), visited ++ idle}
  end

  defp serve(tenant, taken, round_no, now, quantum, max_jobs) do
    {due, later} = Enum.split_with(tenant.waits, &(&1.scheduled_at <= now))
    due = Enum.sort_by(due, &{&1.priority, &1.scheduled_at, &1.id})

    {taken, deficit, rest} =
      take(due, tenant.deficit + tenant.weight * quantum, taken, tenant.key, max_jobs)

    deficit = if rest == [], do: 0, else: deficit

    {%{tenant | deficit: deficit, last_served_round: round_no, waits: rest ++ later}, taken}
  end

  defp take([wait | rest] = due, deficit, taken, key, max_jobs) do
    if wait.cost > deficit or length(taken) >= max_jobs,
      do: {taken, deficit, due},
      else: take(rest, deficit - wait.cost, [{key, wait} | taken], key, max_jobs)
  end

  defp take([], deficit, taken, _key, _max_jobs), do: {taken, deficit, []}
end
