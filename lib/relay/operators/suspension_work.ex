defmodule Relay.Operators.SuspensionWork do
  @moduledoc """
  The pending work of a suspended tenant or subtenant (TN-10), with the mechanism of a kill switch (TN-40). When a suspension takes effect, every pending delivery of the tenant in both environments, or of the subtenant's notifications, is marked `PAUSED` with the rule `tenant.suspended` or `subtenant.suspended`, batch by batch: it is not deleted, not counted as an error and not retried. Lifting the suspension is the explicit resume: each delivery the suspension paused passes the policy lattice again (`Relay.Policy.Lattice`); `send` lifts the pause and queues its delivery job when none waits, `skip` cancels it with the lattice's rule, and a lattice that is not ready leaves the rest `PAUSED` until it is.
  """

  alias Relay.Actor
  alias Relay.Operators.Store
  alias Relay.Policy.Lattice
  alias Relay.Scope

  @batch 500
  @max_batches 100

  @type totals :: %{paused: non_neg_integer()}
  @type resumed :: %{resumed: non_neg_integer(), cancelled: non_neg_integer(), waiting: boolean()}

  # TN-10
  # TN-40
  @doc "The pause rule of a tenant (`nil`) or subtenant suspension."
  @spec rule(Relay.Id.t() | nil) :: String.t()
  def rule(nil), do: "tenant.suspended"
  def rule(_subtenant_id), do: "subtenant.suspended"

  # TN-10
  # TN-40
  @doc "Marks the pending deliveries of a suspended tenant or subtenant `PAUSED` in both environments; returns how many were paused."
  @spec pause(Relay.Id.t(), Relay.Id.t() | nil) :: {:ok, totals()} | {:error, term()}
  def pause(tenant_id, subtenant_id) do
    rule = rule(subtenant_id)

    Enum.reduce_while(scopes(tenant_id), {:ok, %{paused: 0}}, fn scope, {:ok, acc} ->
      case pause_scope(scope, subtenant_id, rule, 0, 1) do
        {:ok, paused} -> {:cont, {:ok, %{acc | paused: acc.paused + paused}}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp pause_scope(_scope, _subtenant_id, _rule, total, batch) when batch > @max_batches,
    do: {:ok, total}

  defp pause_scope(scope, subtenant_id, rule, total, batch) do
    work = fn _status ->
      ids = Store.pending_deliveries(subtenant_id, @batch)
      {length(ids), Enum.count(ids, &(Store.delivery_pause(&1, rule) == :paused))}
    end

    case Store.in_scope(scope, work) do
      {:ok, {@batch, paused}} -> pause_scope(scope, subtenant_id, rule, total + paused, batch + 1)
      {:ok, {_seen, paused}} -> {:ok, total + paused}
      {:error, error} -> {:error, error}
    end
  end

  # TN-10
  # TN-40
  # TN-70 (2)
  @doc "Resumes, through the policy lattice, the deliveries a lifted suspension paused in both environments. `opts`: `:lattice` (defaults to the configured one) and `:actor`, who cancels a delivery the lattice skips."
  @spec resume(Relay.Id.t(), Relay.Id.t() | nil, keyword()) :: {:ok, resumed()} | {:error, term()}
  def resume(tenant_id, subtenant_id, opts \\ []) do
    run = %{
      rule: rule(subtenant_id),
      subtenant_id: subtenant_id,
      lattice: Keyword.get(opts, :lattice, Lattice.impl()),
      actor: Keyword.fetch!(opts, :actor)
    }

    tenant_id
    |> scopes()
    |> Enum.reduce_while({:ok, %{resumed: 0, cancelled: 0, waiting: false}}, fn scope, acc ->
      case resume_scope(scope, run, acc, 1) do
        {:ok, %{waiting: true}} = done -> {:halt, done}
        {:ok, _totals} = next -> {:cont, next}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resume_scope(_scope, _run, acc, batch) when batch > @max_batches, do: acc

  defp resume_scope(scope, run, {:ok, totals}, batch) do
    read = fn _status -> Store.paused_deliveries(run.rule, run.subtenant_id, @batch) end

    case Store.in_scope(scope, read) do
      {:ok, rows} ->
        result = Enum.reduce_while(rows, {:ok, totals}, &resume_one(scope, &1, run, &2))

        case result do
          {:ok, %{waiting: false}} when length(rows) == @batch ->
            resume_scope(scope, run, result, batch + 1)

          other ->
            other
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp resume_one(scope, row, run, {:ok, acc}) do
    case Lattice.reevaluate(%{scope: scope, delivery_id: row["id"]}, run.lattice) do
      {:error, :not_ready} ->
        {:halt, {:ok, %{acc | waiting: true}}}

      {:send, decision_ref} ->
        case Store.in_scope(scope, fn _status -> send(scope, row, decision_ref, run.rule) end) do
          {:ok, :resumed} -> {:cont, {:ok, %{acc | resumed: acc.resumed + 1}}}
          {:ok, _other} -> {:cont, {:ok, acc}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {:skip, _reason, rule_id} ->
        case cancel(scope, row["id"], rule_id, run.actor) do
          {:ok, :cancelled} -> {:cont, {:ok, %{acc | cancelled: acc.cancelled + 1}}}
          {:ok, _other} -> {:cont, {:ok, acc}}
          {:error, error} -> {:halt, {:error, error}}
        end
    end
  end

  defp send(scope, row, decision_ref, rule) do
    with :resumed <- Store.delivery_resume(row["id"], decision_ref, rule <> ".resume"),
         false <- Store.delivery_job?(row["id"]),
         {:ok, _queued} <- Relay.Platform.enqueue_job(job(scope, row)) do
      :resumed
    else
      true -> :resumed
      {:error, %Relay.Error{} = error} -> Store.rollback(error)
      other -> other
    end
  end

  # T-15
  defp job(scope, row) do
    class = String.to_existing_atom(row["message_class"])

    %{
      id: Relay.Id.generate(),
      lane: Relay.Platform.lane(class),
      worker: Relay.Delivery.send_worker(),
      args:
        scope
        |> Scope.to_job_args()
        |> Map.merge(%{
          "notification_id" => Relay.Id.to_string(row["notification_id"]),
          "delivery_id" => Relay.Id.to_string(row["id"])
        }),
      ref_kind: "delivery",
      ref_id: row["id"],
      priority: Relay.Platform.job_priority(:delivery, 1, :normal)
    }
  end

  defp cancel(scope, delivery_id, rule_id, %Actor{} = actor) do
    target = Relay.Id.to_string(delivery_id)

    action = "delivery.cancelled"
    digest = Relay.Operators.record_digest(scope, action, actor, "delivery", target, rule_id)
    work = fn _status -> Store.delivery_cancel(delivery_id, rule_id, digest, actor) end
    Store.in_scope(scope, work)
  end

  defp scopes(tenant_id), do: Enum.map(Relay.Environment.all(), &Scope.new!(tenant_id, &1))
end
