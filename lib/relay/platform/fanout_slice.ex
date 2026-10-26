defmodule Relay.Platform.FanoutSlice do
  @moduledoc """
  The job of one fan-out slice (T-23). It carries only the fan-out, the slice number and the slice's lower bound. It begins or resumes the slice, then runs sub-batches, each in its own scoped transaction: the cancellation and pause check, one keyset page from the source after the checkpoint, the source's records for that page and the new checkpoint commit together. A paused fan-out snoozes the job for 60 seconds; a cancelled one ends the slice `cancelled`. A crash retries from the checkpoint; when the last attempt fails the slice ends `failed`, so the fan-out can still close as `partial`.
  """

  use Relay.Worker, queue: :l2, max_attempts: 5, timeout: 900_000

  alias Relay.Platform.Fanout
  alias Relay.Platform.FanoutStore

  @snooze_s 60

  # T-23
  # TN-54
  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, fanout_id} <- Relay.Id.parse(args["fanout_id"]),
         {:ok, range_from} <- optional_id(args["range_from"]),
         slice_no when is_integer(slice_no) and slice_no >= 0 <- args["slice_no"] do
      slice = %{scope: scope, fanout_id: fanout_id, slice_no: slice_no, range_from: range_from}

      try do
        start(slice)
      rescue
        error ->
          if job.attempt >= job.max_attempts, do: finish(slice, :failed)
          reraise error, __STACKTRACE__
      end
    else
      _ -> {:discard, :invalid_args}
    end
  end

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(text), do: Relay.Id.parse(text)

  defp start(slice) do
    {:ok, begun} =
      FanoutStore.in_scope(slice.scope, fn _ ->
        case FanoutStore.slice_begin(slice.fanout_id, slice.slice_no) do
          {result, checkpoint, range_to} when result in [:begun, :resumed] ->
            {:run, FanoutStore.get(slice.fanout_id), checkpoint, range_to}

          {result, _checkpoint, _range_to} ->
            result
        end
      end)

    case begun do
      {:run, fanout, checkpoint, range_to} ->
        position = if checkpoint, do: {:after, checkpoint}, else: {:from, slice.range_from}
        run(slice, fanout, Fanout.source(fanout.source_kind), position, range_to)

      :cancelled ->
        finish(slice, :cancelled)

      :paused ->
        {:snooze, @snooze_s}

      _terminal_or_missing ->
        :ok
    end
  end

  defp run(slice, fanout, source, position, range_to) do
    {:ok, step} =
      FanoutStore.in_scope(slice.scope, fn _ ->
        case FanoutStore.checkpoint(slice.fanout_id, slice.slice_no, nil, 0, 0) do
          :continue -> sub_batch(slice, fanout, source, position, range_to)
          other -> other
        end
      end)

    case step do
      {:continue, next} -> run(slice, fanout, source, next, range_to)
      :done -> finish(slice, :completed)
      :cancelled -> finish(slice, :cancelled)
      :paused -> {:snooze, @snooze_s}
      :not_running -> :ok
    end
  end

  defp sub_batch(slice, fanout, source, position, range_to) do
    limit = fanout.sub_batch_size

    case source.page(slice.scope, fanout, position, range_to, limit) do
      [] ->
        :done

      ids ->
        {processed, failed} = source.process(slice.scope, fanout, ids)
        last = List.last(ids)

        case FanoutStore.checkpoint(slice.fanout_id, slice.slice_no, last, processed, failed) do
          :continue when length(ids) < limit -> :done
          :continue -> {:continue, {:after, last}}
          other -> other
        end
    end
  end

  defp finish(slice, state) do
    {:ok, _} =
      FanoutStore.in_scope(slice.scope, fn _ ->
        FanoutStore.slice_finish(slice.fanout_id, slice.slice_no, state)
      end)

    :ok
  end
end
