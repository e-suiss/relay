defmodule Relay.Platform.FanoutStore do
  @moduledoc """
  Data access for fan-out tracking through the `relay_fn.fanout_*` functions, and the enqueue of slice jobs in front of the bulk lanes through `relay_fn.drr_enqueue`, inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Rolls the current transaction back with `reason`."
  @spec rollback(term()) :: no_return()
  def rollback(reason), do: Repo.rollback(reason)

  # T-23
  @doc "Creates the fan-out and its pending slices from the slice bounds."
  @spec create(map()) ::
          {:created | :exists, Relay.Id.t(), non_neg_integer()} | :invalid_bounds | :tenant_inactive
  def create(fanout) do
    [row] =
      Repo.call!("relay_fn.fanout_create", [
        fanout.id,
        fanout.source_kind,
        fanout.source_id,
        Atom.to_string(fanout.lane),
        Atom.to_string(fanout.mode),
        fanout.slice_size,
        fanout.sub_batch_size,
        fanout.bounds
      ])

    case Repo.code!(row["result"], [:created, :exists, :invalid_bounds, :tenant_inactive]) do
      code when code in [:created, :exists] -> {code, row["fanout_id"], row["total_slices"]}
      other -> other
    end
  end

  # T-21
  # T-23
  @doc "Puts a slice job in the tenant's wait table in front of a bulk lane."
  @spec drr_enqueue(map()) ::
          :enqueued | :exists | :queued_cap_exceeded | :lane_not_fair | :tenant_inactive
  def drr_enqueue(job) do
    [row] =
      Repo.call!("relay_fn.drr_enqueue", [
        job.id,
        Atom.to_string(job.lane),
        Atom.to_string(job.lane),
        job.worker,
        job.args,
        job.priority,
        job.cost,
        job.scheduled_at,
        "fanout_slice",
        job.ref_id,
        job.queued_cap
      ])

    Repo.code!(row["drr_enqueue"], [
      :enqueued,
      :exists,
      :queued_cap_exceeded,
      :lane_not_fair,
      :tenant_inactive
    ])
  end

  # T-23
  @doc "Starts or resumes a slice; returns its checkpoint and upper bound."
  @spec slice_begin(Relay.Id.t(), non_neg_integer()) ::
          {atom(), Relay.Id.t() | nil, Relay.Id.t() | nil}
  def slice_begin(fanout_id, slice_no) do
    [row] = Repo.call!("relay_fn.fanout_slice_begin", [fanout_id, slice_no])

    {Repo.code!(row["result"], [
       :begun,
       :resumed,
       :cancelled,
       :paused,
       :already_terminal,
       :not_found
     ]), row["checkpoint_after"], row["range_to"]}
  end

  # T-23 (1)
  # T-23 (4)
  @doc "Checks the fan-out before a sub-batch (`after` nil) or writes the checkpoint after it."
  @spec checkpoint(Relay.Id.t(), non_neg_integer(), Relay.Id.t() | nil, non_neg_integer(), non_neg_integer()) ::
          :continue | :cancelled | :paused | :not_running
  def checkpoint(fanout_id, slice_no, after_id, processed, failed) do
    [row] =
      Repo.call!("relay_fn.fanout_slice_checkpoint", [
        fanout_id,
        slice_no,
        after_id,
        processed,
        failed
      ])

    Repo.code!(row["fanout_slice_checkpoint"], [:continue, :cancelled, :paused, :not_running])
  end

  # T-23 (3)
  @doc "Ends a slice; the last slice closes the fan-out."
  @spec slice_finish(Relay.Id.t(), non_neg_integer(), :completed | :failed | :cancelled) ::
          {:finished | :already_terminal | :not_found, String.t() | nil}
  def slice_finish(fanout_id, slice_no, state) do
    [row] = Repo.call!("relay_fn.fanout_slice_finish", [fanout_id, slice_no, Atom.to_string(state)])
    {Repo.code!(row["result"], [:finished, :already_terminal, :not_found]), row["fanout_state"]}
  end

  # T-34
  @doc "Pauses a fan-out under a rule."
  @spec pause(Relay.Id.t(), String.t()) :: :paused | :already_paused | :not_running
  def pause(fanout_id, rule_id) do
    [row] = Repo.call!("relay_fn.fanout_pause", [fanout_id, rule_id])
    Repo.code!(row["fanout_pause"], [:paused, :already_paused, :not_running])
  end

  @doc "Resumes a paused fan-out."
  @spec resume(Relay.Id.t()) :: :resumed | :not_paused
  def resume(fanout_id) do
    [row] = Repo.call!("relay_fn.fanout_resume", [fanout_id])
    Repo.code!(row["fanout_resume"], [:resumed, :not_paused])
  end

  # T-23 (4)
  @doc "Cancels a fan-out; pending slices are cancelled at once and running ones stop at their next checkpoint."
  @spec cancel(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          {:cancelled | :already_closed | :not_found, non_neg_integer()}
  def cancel(fanout_id, rule_id, digest, %Actor{} = actor) do
    [row] =
      Repo.call!("relay_fn.fanout_cancel", [fanout_id, rule_id, digest | Actor.params(actor)])

    {Repo.code!(row["result"], [:cancelled, :already_closed, :not_found]), row["cancelled_slices"]}
  end

  # T-23 (6)
  @doc "Reads the progress row of a fan-out."
  @spec get(Relay.Id.t()) :: map() | nil
  def get(fanout_id) do
    case Repo.call!("relay_fn.fanout_get", [fanout_id]) do
      [row] ->
        %{
          id: row["id"],
          source_kind: row["source_kind"],
          source_id: row["source_id"],
          lane: row["lane"],
          mode: row["mode"],
          slice_size: row["slice_size"],
          sub_batch_size: row["sub_batch_size"],
          state: row["state"],
          total_slices: row["total_slices"],
          slices_completed: row["slices_completed"],
          slices_failed: row["slices_failed"],
          slices_cancelled: row["slices_cancelled"],
          processed_count: row["processed_count"],
          failed_count: row["failed_count"],
          pause_rule_id: row["pause_rule_id"],
          close_rule_id: row["close_rule_id"],
          closed_at: row["closed_at"]
        }

      [] ->
        nil
    end
  end
end
