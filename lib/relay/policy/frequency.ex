defmodule Relay.Policy.Frequency do
  @moduledoc """
  The frequency cap, a shaper (PC-50, PC-58 (6)). It applies only to `marketing`, `social` and `operational`. Two counters may apply to a delivery: the recipient's global cap over external channels (every channel but in-app and webhook), 12 deliveries in a rolling 24 hours unless the tenant sets a lower value, and the category × channel policy of the category when it sets a limit and a window. A capped delivery meets the fate of its category policy, by default `drop` for `marketing`, `defer` for `operational` and `digest` for `social`. Only a send decision is counted, by the delivery's id, so counting the same delivery again changes nothing.
  """

  alias Relay.Policy.Snapshot

  @global_cap 12
  @global_window_ms 86_400_000
  @classes [:marketing, :social, :operational]
  @internal_channels [:in_app, :webhook]
  @default_fates %{marketing: :drop, operational: :defer, social: :digest}

  @type key :: %{
          kind: :global | :policy,
          limit: pos_integer(),
          window_ms: pos_integer(),
          category: String.t() | nil,
          channel: Snapshot.channel() | nil
        }
  @type check :: :pass | :unavailable | {:capped, :global | :policy, DateTime.t() | nil}

  # PC-50
  @doc "The platform's global cap: deliveries per recipient in the global window."
  @spec global_cap() :: pos_integer()
  def global_cap, do: @global_cap

  @doc "The global window in milliseconds."
  @spec global_window_ms() :: pos_integer()
  def global_window_ms, do: @global_window_ms

  # PC-50
  # PC-58 (6)
  @doc "The global cap in force: the tenant's value when it is lower than the platform's, otherwise the platform's."
  @spec effective_global_cap(pos_integer() | nil) :: pos_integer()
  def effective_global_cap(nil), do: @global_cap
  def effective_global_cap(cap) when is_integer(cap) and cap > 0, do: min(cap, @global_cap)

  # PC-50
  @doc "Returns true if the frequency cap applies to the class."
  @spec applies?(Snapshot.message_class()) :: boolean()
  def applies?(class), do: class in @classes

  # PC-50
  # PC-58 (6)
  @doc "The counters that apply to a delivery of `class` on `channel` in `category`; empty for an exempt class."
  @spec keys(
          Snapshot.message_class(),
          Snapshot.channel(),
          String.t(),
          Snapshot.frequency_policy() | nil,
          pos_integer() | nil
        ) :: [key()]
  def keys(class, channel, category_key, policy, tenant_cap) do
    if applies?(class),
      do: global(channel, tenant_cap) ++ policy(category_key, channel, policy),
      else: []
  end

  defp global(channel, _cap) when channel in @internal_channels, do: []

  defp global(_channel, cap) do
    [
      %{
        kind: :global,
        limit: effective_global_cap(cap),
        window_ms: @global_window_ms,
        category: nil,
        channel: nil
      }
    ]
  end

  defp policy(category, channel, %{limit: limit, window_ms: window})
       when is_integer(limit) and limit > 0 and is_integer(window) and window > 0 do
    [%{kind: :policy, limit: limit, window_ms: window, category: category, channel: channel}]
  end

  defp policy(_category, _channel, _policy), do: []

  # PC-50
  # PC-57 (1)
  @doc "The fate of a capped delivery: the category policy's, otherwise the class default."
  @spec fate(Snapshot.message_class(), Snapshot.frequency_policy() | nil) :: Snapshot.fate()
  def fate(_class, %{fate: fate}) when fate in [:drop, :defer, :digest, :inbox_only], do: fate
  def fate(class, _policy), do: Map.fetch!(@default_fates, class)

  # PC-50
  # INV-45
  @doc "Checks the readings against the counters: `:pass`, `:unavailable` when a reading is missing (the cap then fails open), or `{:capped, kind, free_at}` with the first capped counter and the latest time a slot frees."
  @spec check([key()], Snapshot.readings() | :unavailable) :: check()
  def check([], _readings), do: :pass
  def check(_keys, :unavailable), do: :unavailable

  def check(keys, readings) when is_map(readings) do
    found = Enum.map(keys, &{&1, Map.get(readings, &1.kind)})

    if Enum.all?(found, fn {_key, reading} -> is_map(reading) end),
      do: capped(for {key, reading} <- found, reading.count >= key.limit, do: {key, reading}),
      else: :unavailable
  end

  defp capped([]), do: :pass

  defp capped([{first, _} | _] = hits) do
    free = for {_key, %{free_at: %DateTime{} = at}} <- hits, do: at
    {:capped, first.kind, if(free == [], do: nil, else: Enum.max(free, DateTime))}
  end
end
