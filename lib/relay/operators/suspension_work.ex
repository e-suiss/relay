defmodule Relay.Operators.SuspensionWork do
  @moduledoc """
  The pending work of a suspended tenant, subtenant or subscriber (TN-10, TN-73), with the mechanism of a kill switch (TN-40). When a suspension takes effect, every pending delivery of the tenant in both environments, of the subtenant's notifications or of the subscriber's notifications is marked `PAUSED` with the rule `tenant.suspended`, `subtenant.suspended` or `subscriber.suspended`, batch by batch: it is not deleted, not counted as an error and not retried. Lifting the suspension is the explicit resume: each delivery the suspension paused passes the policy lattice again (`Relay.Policy.Lattice`); `send` lifts the pause and queues its delivery job when none waits, and so do `defer` and `pause`, since the job's run records the deferral or pauses the delivery under the kill switch that holds it; `skip` cancels it with the lattice's rule, `expire` closes it as `expired`, and a lattice that is not ready, or one of whose inputs cannot be read, leaves the rest `PAUSED` until it is. A delivery whose tenant, subtenant or subscriber is still suspended is not resumed: it stays `PAUSED` under the rule of the suspension that still holds it, whose lift resumes it.
  """

  alias Relay.Actor
  alias Relay.Operators.Store
  alias Relay.Policy.Lattice
  alias Relay.Scope

  @batch 500
  @max_batches 100
  @subscriber_rule "subscriber.suspended"

  @type totals :: %{paused: non_neg_integer()}
  @type resumed :: %{
          required(:resumed) => non_neg_integer(),
          required(:cancelled) => non_neg_integer(),
          required(:waiting) => boolean(),
          optional(:expired) => non_neg_integer()
        }

  # TN-10
  # TN-40
  @doc "The pause rule of a tenant (`nil`) or subtenant suspension."
  @spec rule(Relay.Id.t() | nil) :: String.t()
  def rule(nil), do: "tenant.suspended"
  def rule(_subtenant_id), do: "subtenant.suspended"

  # TN-73
  @doc "The pause rule of a subscriber suspension."
  @spec subscriber_rule() :: String.t()
  def subscriber_rule, do: @subscriber_rule

  # TN-10
  # TN-40
  @doc "Marks the pending deliveries of a suspended tenant or subtenant `PAUSED` in both environments; returns how many were paused."
  @spec pause(Relay.Id.t(), Relay.Id.t() | nil) :: {:ok, totals()} | {:error, term()}
  def pause(tenant_id, subtenant_id) do
    rule = rule(subtenant_id)
    filter = %{subtenant_id: subtenant_id}

    Enum.reduce_while(scopes(tenant_id), {:ok, %{paused: 0}}, fn scope, {:ok, acc} ->
      case pause_scope(scope, filter, rule, 0, 1) do
        {:ok, paused} -> {:cont, {:ok, %{acc | paused: acc.paused + paused}}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # TN-73
  # TN-40
  @doc "Marks the pending deliveries of a suspended subscriber of `scope` `PAUSED` with the rule `subscriber.suspended`; returns how many were paused."
  @spec pause_subscriber(Scope.t(), Relay.Id.t()) :: {:ok, totals()} | {:error, term()}
  def pause_subscriber(%Scope{} = scope, recipient_id) do
    case pause_scope(scope, %{recipient_id: recipient_id}, @subscriber_rule, 0, 1) do
      {:ok, paused} -> {:ok, %{paused: paused}}
      {:error, error} -> {:error, error}
    end
  end

  defp pause_scope(_scope, _filter, _rule, total, batch) when batch > @max_batches,
    do: {:ok, total}

  defp pause_scope(scope, filter, rule, total, batch) do
    work = fn _status ->
      ids = Store.pending_deliveries(filter, @batch)
      {length(ids), Enum.count(ids, &(Store.delivery_pause(&1, rule) == :paused))}
    end

    case Store.in_scope(scope, work) do
      {:ok, {@batch, paused}} -> pause_scope(scope, filter, rule, total + paused, batch + 1)
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
    run = run(rule(subtenant_id), %{subtenant_id: subtenant_id}, opts)

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

  # TN-73
  # TN-40
  @doc "Resumes, through the policy lattice, the deliveries of a subscriber of `scope` whose suspension was lifted; `opts` as in `resume/3`."
  @spec resume_subscriber(Scope.t(), Relay.Id.t(), keyword()) ::
          {:ok, resumed()} | {:error, term()}
  def resume_subscriber(%Scope{} = scope, recipient_id, opts) do
    run = run(@subscriber_rule, %{recipient_id: recipient_id}, opts)
    resume_scope(scope, run, {:ok, %{resumed: 0, cancelled: 0, waiting: false}}, 1)
  end

  defp run(rule, filter, opts) do
    %{
      rule: rule,
      filter: filter,
      lattice: Keyword.get(opts, :lattice, Lattice.impl()),
      actor: Keyword.fetch!(opts, :actor)
    }
  end

  defp resume_scope(_scope, _run, acc, batch) when batch > @max_batches, do: acc

  defp resume_scope(scope, run, {:ok, totals}, batch) do
    read = fn status -> {status, Store.paused_deliveries(run.rule, run.filter, @batch)} end

    case Store.in_scope(scope, read) do
      {:ok, {status, rows}} ->
        result = Enum.reduce_while(rows, {:ok, totals}, &resume_one(scope, status, &1, run, &2))

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

  defp resume_one(scope, status, row, run, {:ok, acc}) do
    case holding(status, row, run.rule) do
      nil -> reevaluate(scope, row, run, acc)
      rule -> hold(scope, row, run.rule, rule, acc)
    end
  end

  # TN-10
  # TN-73
  defp holding(status, row, rule) do
    cond do
      status != :active and rule != "tenant.suspended" -> "tenant.suspended"
      row["subtenant_suspended"] and rule != "subtenant.suspended" -> "subtenant.suspended"
      row["recipient_suspended"] and rule != @subscriber_rule -> @subscriber_rule
      true -> nil
    end
  end

  defp hold(scope, row, from, to, acc) do
    work = fn _status ->
      with :resumed <- Store.delivery_resume(row["id"], to, from <> ".resume"),
           do: Store.delivery_pause(row["id"], to)
    end

    case Store.in_scope(scope, work) do
      {:ok, _result} -> {:cont, {:ok, acc}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp reevaluate(scope, row, run, acc) do
    case Lattice.reevaluate(%{scope: scope, delivery_id: row["id"]}, run.lattice) do
      {:error, :not_ready} ->
        {:halt, {:ok, %{acc | waiting: true}}}

      {:send, decision_ref} ->
        resume_send(scope, row, decision_ref, run, acc)

      {:defer, _reason, rule_id, _until} ->
        resume_send(scope, row, "lattice:" <> rule_id, run, acc)

      {:pause, rule_id} ->
        resume_send(scope, row, "lattice:" <> rule_id, run, acc)

      {:skip, _reason, rule_id} ->
        scope |> cancel(row["id"], rule_id, run.actor) |> count(acc, :cancelled)

      {:expire, rule_id} ->
        scope
        |> Store.in_scope(fn _status -> Store.delivery_expire(row["id"], rule_id) end)
        |> count(acc, :expired)
    end
  end

  defp resume_send(scope, row, decision_ref, run, acc) do
    scope
    |> Store.in_scope(fn _status -> send(scope, row, decision_ref, run.rule) end)
    |> count(acc, :resumed)
  end

  defp count({:ok, result}, acc, result),
    do: {:cont, {:ok, Map.update(acc, result, 1, &(&1 + 1))}}
  defp count({:ok, _other}, acc, _result), do: {:cont, {:ok, acc}}
  defp count({:error, error}, _acc, _result), do: {:halt, {:error, error}}

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
