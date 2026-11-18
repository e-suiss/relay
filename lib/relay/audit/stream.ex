defmodule Relay.Audit.Checkpointer.Stream do
  @moduledoc """
  The `audit_stream` singleton task: the continuous stream of the audit records to the SIEM (TN-49). Each step reads the records integrated into the log since its cursor, in leaf order, and hands the batch to every configured publication target whose module streams records (`stream/3`, as `Relay.Audit.Checkpointer.Publisher.Siem` does). The cursor moves only when every such target accepted the batch, so a target that cannot be reached gets the same batch again on the next step and no record is skipped; a record can arrive more than once. A new log of the next UTC year is followed once the earlier one is drained. Without a streaming target the task only waits.

  Telemetry: `[:relay, :audit, :stream]` with the target and `ok` or `failed`, and the count of records.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Audit.Checkpointer.State
  alias Relay.Platform.Maintenance.EscapeHatch

  @page 500
  @idle_ms 5_000
  @busy_ms 200

  # TN-49
  @impl Relay.Platform.Leadership
  @doc "Streams the next batch of audit records."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: saved}) do
    config = Application.get_env(:relay, Relay.Audit, [])
    current = State.origin(Keyword.fetch!(config, :log_host), Relay.Clock.utc_now().year)
    step(saved, current, targets(Keyword.get(config, :publishers, [])))
  end

  @doc "The configured targets that stream records."
  @spec targets([{String.t(), module(), keyword()}]) :: [{String.t(), module(), keyword()}]
  def targets(publishers) do
    Enum.filter(publishers, fn {_target, module, _opts} ->
      Code.ensure_loaded?(module) and function_exported?(module, :stream, 3)
    end)
  end

  @doc "One step from the saved cursor (the log origin and the next leaf index), with `current` the log of this year."
  @spec step(map() | nil, String.t(), [{String.t(), module(), keyword()}]) ::
          Relay.Platform.Leadership.step()
  def step(saved, current, []), do: {:ok, cursor(saved, current), @idle_ms}

  def step(saved, current, targets) do
    %{"origin" => origin, "next" => next} = state = cursor(saved, current)

    case EscapeHatch.audit_stream_page(origin, next, @page) do
      {:ok, []} when origin != current ->
        {:ok, %{"origin" => current, "next" => 0}, @busy_ms}

      {:ok, []} ->
        {:ok, state, @idle_ms}

      {:ok, records} ->
        send_batch(state, origin, records, targets)

      {:error, error} ->
        {:error, error}
    end
  end

  defp send_batch(state, origin, records, targets) do
    accepted = Enum.all?(Enum.map(targets, &send_one(&1, origin, records)))

    if accepted do
      last = List.last(records).leaf_index
      delay = if length(records) == @page, do: @busy_ms, else: @idle_ms
      {:ok, %{state | "next" => last + 1}, delay}
    else
      {:ok, state, @idle_ms}
    end
  end

  defp send_one({target, module, opts}, origin, records) do
    case module.stream(origin, records, opts) do
      :ok ->
        measure(target, :ok, records)
        true

      {:error, %Relay.Error{code: code}} ->
        measure(target, :failed, records)
        Logger.warning("audit records were not streamed", target: target, code: code)
        false
    end
  end

  defp measure(target, result, records) do
    :telemetry.execute([:relay, :audit, :stream], %{count: length(records)}, %{
      target: target,
      result: result
    })
  end

  defp cursor(%{"origin" => origin, "next" => next} = saved, _current)
       when is_binary(origin) and is_integer(next) and next >= 0,
       do: Map.take(saved, ["origin", "next"])

  defp cursor(_saved, current), do: %{"origin" => current, "next" => 0}
end
