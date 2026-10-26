defmodule Relay.Platform.Fanout do
  @moduledoc """
  Fan-out slicing and batch tracking, Relay's own component (T-23, TN-54, MD-7). A large audience is cut into slices of at most `slice_size` recipients (5,000 by default) by keyset bounds on the recipient identifier; a slice job carries only its range, never a recipient list, and there is no job per recipient. A slice runs sub-batches of `sub_batch_size` (200 by default): before each sub-batch it checks whether the fan-out was cancelled or paused, then the sub-batch's records and its checkpoint commit together, so a retried slice continues after its checkpoint (T-23 items 1 and 4).

  Progress lives in `relay.fanouts`, one update per finished slice; the fan-out closes when every slice is terminal: `completed`, or `partial` with a `fanout.partial` event to the tenant when some slices failed or were cancelled; a cancelled fan-out ends `cancelled` (T-23 item 3).

  Slice jobs of the `l1` lane go to its queue directly; those of the bulk lanes `l2` and `l3` wait in the tenant's DRR table (`Relay.Platform.Fairness.Queueing.enqueue/2`) at priority 5 for the first slice and 6 for the others, in the transaction that creates the fan-out, written in parts of 500 (T-32 item 5, T-36).
  """

  alias Relay.Platform.Fairness.Drr
  alias Relay.Platform.Fairness.Job
  alias Relay.Platform.Fairness.Queueing
  alias Relay.Platform.FanoutSlice
  alias Relay.Platform.FanoutStore

  @slice_size 5_000
  @sub_batch_size 200
  @chunk 500

  @type mode :: :normal | :bulk | :campaign

  # T-23 (2)
  # T-91
  @doc "The fan-out model for an audience size (ENGINEERING ASSUMPTION, T-91): up to 1,000 recipients normal, up to 100,000 bulk, above that campaign."
  @spec mode(non_neg_integer()) :: mode()
  def mode(count) when is_integer(count) and count >= 0 and count <= 1_000, do: :normal
  def mode(count) when is_integer(count) and count <= 100_000, do: :bulk
  def mode(count) when is_integer(count), do: :campaign

  # T-23
  @doc "Default slice and sub-batch sizes (⚠ T-23, set by measurement)."
  @spec default_sizes() :: %{slice_size: pos_integer(), sub_batch_size: pos_integer()}
  def default_sizes, do: %{slice_size: @slice_size, sub_batch_size: @sub_batch_size}

  # T-23
  @doc """
  Creates a fan-out and queues one job per slice in one transaction. `attrs` carries `:id`, `:source_kind`, `:source_id`, `:lane` (`:l1`, `:l2` or `:l3`), `:bounds` (the `n + 1` keyset bounds of `n` slices, `nil` allowed only as the first or last element), and `:mode` or `:recipient_count`; `:slice_size` and `:sub_batch_size` default to 5,000 and 200. A repeated source returns `:exists` and queues nothing.
  """
  @spec create(Relay.Scope.t(), map()) ::
          {:ok,
           {:created | :exists, Relay.Id.t(), non_neg_integer()}
           | :invalid_bounds
           | :tenant_inactive}
          | {:error, term()}
  def create(%Relay.Scope{} = scope, attrs) do
    fanout =
      attrs
      |> Map.put_new(:slice_size, @slice_size)
      |> Map.put_new(:sub_batch_size, @sub_batch_size)
      |> Map.put_new_lazy(:mode, fn -> mode(Map.fetch!(attrs, :recipient_count)) end)

    FanoutStore.in_scope(scope, fn _status ->
      case FanoutStore.create(fanout) do
        {:created, id, total} = created ->
          :ok = enqueue(scope, fanout, id, total)
          created

        other ->
          other
      end
    end)
  end

  defp enqueue(scope, fanout, id, total) do
    0..(total - 1)//1
    |> Enum.zip(Enum.slice(fanout.bounds, 0, total))
    |> Enum.chunk_every(@chunk)
    |> Enum.each(&enqueue_chunk(scope, fanout, id, &1))
  end

  defp enqueue_chunk(scope, %{lane: :l1}, id, slices) do
    jobs =
      for {slice_no, range_from} <- slices do
        FanoutSlice.new(args(scope, id, slice_no, range_from),
          queue: :l1,
          priority: priority(slice_no)
        )
      end

    _ = Oban.insert_all(jobs)
    :ok
  end

  defp enqueue_chunk(scope, %{lane: lane} = fanout, id, slices) when lane in [:l2, :l3] do
    Enum.each(slices, fn {slice_no, range_from} ->
      job = %Job{
        id: Relay.Id.generate(),
        lane: lane,
        worker: FanoutSlice,
        args: args(scope, id, slice_no, range_from),
        ref_kind: "fanout_slice",
        ref_id: id,
        priority: priority(slice_no),
        cost: min(fanout.slice_size, Drr.quantum())
      }

      case Queueing.enqueue(job) do
        {:ok, result} when result in [:waiting, :exists] -> :ok
        other -> FanoutStore.rollback({:not_queued, other})
      end
    end)
  end

  defp args(scope, fanout_id, slice_no, range_from) do
    scope
    |> Relay.Scope.to_job_args()
    |> Map.merge(%{
      "fanout_id" => Relay.Id.to_string(fanout_id),
      "slice_no" => slice_no,
      "range_from" => range_from && Relay.Id.to_string(range_from)
    })
  end

  defp priority(0), do: 5
  defp priority(_slice_no), do: 6

  # T-34
  # TN-40
  @doc "Pauses a pending or running fan-out under a rule; its slices snooze until it resumes."
  @spec pause(Relay.Scope.t(), Relay.Id.t(), String.t()) ::
          {:ok, :paused | :already_paused | :not_running} | {:error, term()}
  def pause(scope, fanout_id, rule_id),
    do: FanoutStore.in_scope(scope, fn _ -> FanoutStore.pause(fanout_id, rule_id) end)

  # TN-40
  @doc "Resumes a paused fan-out. The caller has passed the policy lattice first."
  @spec resume(Relay.Scope.t(), Relay.Id.t()) :: {:ok, :resumed | :not_paused} | {:error, term()}
  def resume(scope, fanout_id),
    do: FanoutStore.in_scope(scope, fn _ -> FanoutStore.resume(fanout_id) end)

  # T-23 (4)
  @doc "Cancels a fan-out, audited with the caller's record digest; pending slices are cancelled at once, a running slice stops before its next sub-batch."
  @spec cancel(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, {:cancelled | :already_closed | :not_found, non_neg_integer()}} | {:error, term()}
  def cancel(scope, fanout_id, rule_id, record_digest, actor),
    do:
      FanoutStore.in_scope(scope, fn _ ->
        FanoutStore.cancel(fanout_id, rule_id, record_digest, actor)
      end)

  # T-23 (6)
  @doc "Reads a fan-out's progress."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(scope, fanout_id),
    do: FanoutStore.in_scope(scope, fn _ -> FanoutStore.get(fanout_id) end)

  @doc "The source module configured for a source kind."
  @spec source(String.t()) :: module() | nil
  def source(kind) when is_binary(kind),
    do:
      :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:sources, %{}) |> Map.get(kind)
end
