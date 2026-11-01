defmodule Relay.Policy.FrequencyCounter do
  @moduledoc """
  The frequency counters on Valkey (PC-50, PC-58 (6)): a sliding window per recipient (`fq:g:<recipient>`) and per recipient × category × channel (`fq:p:<recipient>:<category digest>:<channel>`) under the tenant prefix, whose members are delivery ids. `read/5` returns the readings the lattice snapshot carries; `record/5` counts a delivery once the lattice decided to send it. The counters come from `Relay.Policy.frequency_counters/1`.

  This is the only part of the lattice that touches a backend, so it is a boundary of its own. When Valkey does not answer, `read/5` returns `:unavailable` and the cap fails open (INV-45); either failure emits `[:relay, :frequency_counter, :unavailable]` telemetry, exported as `relay_frequency_counter_unavailable_total`, and logs an error.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Platform], exports: []

  require Logger

  @type key :: %{
          required(:kind) => :global | :policy,
          required(:limit) => pos_integer(),
          required(:window_ms) => pos_integer(),
          optional(:category) => String.t() | nil,
          optional(:channel) => atom() | nil
        }
  @type reading :: %{count: non_neg_integer(), free_at: DateTime.t() | nil}
  @type readings :: %{global: reading() | nil, policy: reading() | nil}
  @type option :: {:backend, GenServer.name()} | {:adapter, module()}

  # PC-50
  # PC-58 (6)
  # INV-45
  @doc "Reads the counters of `keys` for a delivery, leaving the delivery itself out; `:unavailable` when any counter cannot be read."
  @spec read(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t(), [key()], [option()]) ::
          readings() | :unavailable
  def read(%Relay.Scope{} = scope, recipient_id, delivery_id, keys, opts \\ []) do
    member = Relay.Id.to_string(delivery_id)

    Enum.reduce_while(keys, %{global: nil, policy: nil}, fn key, readings ->
      %{kind: kind, limit: limit, window_ms: window} = key
      path = path(recipient_id, key)

      case Relay.Platform.sliding_set_count(scope, path, window, member, limit, opts) do
        {:ok, count} -> {:cont, Map.put(readings, kind, reading(count))}
        {:error, error} -> {:halt, unavailable(:read, error)}
      end
    end)
  end

  # PC-50
  # PC-58 (6)
  @doc "Counts a delivery the lattice decided to send in every counter of `keys`; adding it again changes nothing."
  @spec record(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t(), [key()], [option()]) ::
          :ok | :unavailable
  def record(%Relay.Scope{} = scope, recipient_id, delivery_id, keys, opts \\ []) do
    member = Relay.Id.to_string(delivery_id)

    Enum.reduce_while(keys, :ok, fn key, :ok ->
      path = path(recipient_id, key)

      case Relay.Platform.sliding_set_add(scope, path, key.window_ms, member, opts) do
        {:ok, _count} -> {:cont, :ok}
        {:error, error} -> {:halt, unavailable(:record, error)}
      end
    end)
  end

  defp reading(%{count: count, free_at_ms: nil}), do: %{count: count, free_at: nil}

  defp reading(%{count: count, free_at_ms: ms}),
    do: %{count: count, free_at: DateTime.from_unix!(ms, :millisecond)}

  defp path(recipient_id, %{kind: :global}), do: ["fq", "g", Relay.Id.to_string(recipient_id)]

  defp path(recipient_id, %{kind: :policy, category: category, channel: channel}) do
    digest = :crypto.hash(:sha256, category)
    hex = digest |> binary_part(0, 16) |> Base.encode16(case: :lower)
    ["fq", "p", Relay.Id.to_string(recipient_id), hex, Atom.to_string(channel)]
  end

  # PC-50
  defp unavailable(op, %Relay.Error{code: code}) do
    :telemetry.execute([:relay, :frequency_counter, :unavailable], %{count: 1}, %{op: op})
    Logger.error("frequency counter unavailable (#{op}, #{code}); frequency caps fail open")
    :unavailable
  end
end
