defmodule Relay.Audit.Checkpointer.Readback do
  @moduledoc """
  The `audit_readback` singleton task. At the declared checkpoint interval it reads every checkpoint recorded since its cursor back from each readable target that reported it published, and compares the object with the recorded signed note byte for byte. A checkpoint is read back once it is older than the settle time, so that its publications are recorded. A different or missing object is a security event: `[:relay, :audit, :mismatch]` with kind `:published_mismatch` or `:published_missing`, and an error log. A target that cannot be reached holds the cursor, so the checkpoint is read again on the next step.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Audit.Checkpointer.Publisher
  alias Relay.Audit.Checkpointer.State
  alias Relay.Platform.Maintenance.EscapeHatch

  @page 100
  @settle_s 30

  # OP-70
  # OP-63
  @impl Relay.Platform.Leadership
  @doc "Reads the checkpoints recorded since the cursor back from their targets."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{state: saved}), do: step(saved, @settle_s)

  @doc "Runs one read-back step from the saved cursors, reading checkpoints older than `settle_s` seconds."
  @spec step(map() | nil, non_neg_integer()) :: Relay.Platform.Leadership.step()
  def step(saved, settle_s) do
    config = Application.get_env(:relay, Relay.Audit, [])
    publishers = Enum.filter(Keyword.get(config, :publishers, []), &readable?/1)
    current = State.origin(Keyword.fetch!(config, :log_host), Relay.Clock.utc_now().year)
    cursors = cursors(saved)

    origins = Enum.uniq([current | Map.keys(cursors)])

    with {:ok, cursors} <- read_origins(origins, current, cursors, publishers, settle_s) do
      {:ok, %{"cursors" => cursors}, State.interval_ms()}
    end
  end

  defp readable?({_target, module, _opts}), do: Publisher.readable?(module)

  defp read_origins(origins, current, cursors, publishers, settle_s) do
    Enum.reduce_while(origins, {:ok, cursors}, fn origin, {:ok, acc} ->
      cursor = Map.get(acc, origin)

      case EscapeHatch.audit_published_after(origin, decode(cursor), settle_s, @page) do
        {:ok, []} when origin != current -> {:cont, {:ok, Map.delete(acc, origin)}}
        {:ok, []} -> {:cont, {:ok, acc}}
        {:ok, rows} -> {:cont, {:ok, advance(acc, origin, rows, publishers)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp advance(cursors, origin, rows, publishers) do
    case compare_rows(origin, rows, publishers, Map.get(cursors, origin)) do
      nil -> cursors
      cursor -> Map.put(cursors, origin, cursor)
    end
  end

  defp compare_rows(origin, rows, publishers, cursor) do
    Enum.reduce_while(rows, cursor, fn row, acc ->
      case compare(origin, row, publishers) do
        :ok -> {:cont, encode(row)}
        :retry -> {:halt, acc}
      end
    end)
  end

  @doc "Compares one recorded checkpoint with what each of its readable targets returns; returns `:retry` when a target could not be read."
  @spec compare(String.t(), map(), [{String.t(), module(), keyword()}]) :: :ok | :retry
  def compare(origin, row, publishers) do
    checkpoint = %{id: row.id, origin: origin, tree_size: row.tree_size}

    results =
      for {target, module, opts} <- publishers, target in row.targets do
        case module.read(checkpoint, opts) do
          {:ok, note} when note == row.signed_note ->
            :ok

          {:ok, _other} ->
            report(:published_mismatch, origin, target, row.tree_size)

          {:error, %Relay.Error{code: :publication_missing}} ->
            report(:published_missing, origin, target, row.tree_size)

          {:error, %Relay.Error{code: code}} ->
            Logger.warning("audit checkpoint read-back failed", target: target, code: code)
            :retry
        end
      end

    if :retry in results, do: :retry, else: :ok
  end

  defp report(kind, origin, target, tree_size) do
    :telemetry.execute([:relay, :audit, :mismatch], %{count: 1}, %{
      kind: kind,
      origin: origin,
      detail: tree_size
    })

    Logger.error("published audit checkpoint differs from the record",
      kind: kind,
      origin: origin,
      target: target
    )

    :ok
  end

  defp cursors(%{"cursors" => cursors}) when is_map(cursors), do: cursors
  defp cursors(_saved), do: %{}

  defp encode(row),
    do: [row.tree_size, row.heartbeat, DateTime.to_iso8601(row.created_at)]

  defp decode([size, heartbeat, at]) when is_integer(size) and is_boolean(heartbeat) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> {size, heartbeat, at}
      _ -> nil
    end
  end

  defp decode(_cursor), do: nil
end
