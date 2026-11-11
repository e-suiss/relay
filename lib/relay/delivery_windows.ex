defmodule Relay.DeliveryWindows do
  @moduledoc """
  The `delivery_windows` data set and its pure rules: the two-stage DLR windows of the channels that wait for a definite delivery event (DS-18, DS-19). A delivery the provider accepted without a definite event becomes `unknown_pending` when its short window has passed since the acceptance and `unknown` when its long window has passed; nothing is guessed (INV-5).

  A row without a provider is a channel's window, a row with a provider adjusts it for that provider. The installation version holds the defaults (SMS 6 h / 72 h, email 24 h / 72 h, WhatsApp 36 h / 7 d, voice 1 h / 24 h; the WhatsApp and voice values are an engineering assumption until measured, DS-51), and a tenant version adjusts them for the tenant. `resolve/2` keeps every adjusted window between half and twice its channel's installation default, a short window at least 15 minutes, a long window at most 14 days and never shorter than the short one (DS-50). Push, Web Push, in-app, messaging and webhook channels have no window and never become `unknown` (DS-13).
  """

  @channels ~w(sms email whatsapp voice)
  @floor_ms 15 * 60_000
  @ceiling_ms 14 * 24 * 3_600_000

  @type window :: %{required(String.t()) => String.t() | pos_integer() | nil}
  @type stage :: 0 | 1 | 2

  # DS-19
  # DS-13
  @doc "The channels that wait for a definite delivery event and so have windows."
  @spec channels() :: [String.t(), ...]
  def channels, do: @channels

  # DS-50
  @doc "The shortest short window any scope can have, in milliseconds."
  @spec floor_ms() :: pos_integer()
  def floor_ms, do: @floor_ms

  # DS-50
  @doc "Checks the rules of a `delivery_windows` version that its JSON Schema cannot express: each channel and provider at most once and no long window shorter than its short window."
  @spec validate(map()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{} = content) do
    rows = rows(content)
    keys = Enum.map(rows, &{&1["channel"], &1["provider"]})

    checks = [
      unique_windows: length(Enum.uniq(keys)) == length(keys),
      long_not_shorter: Enum.all?(rows, &(&1["long_ms"] >= &1["short_ms"]))
    ]

    case Enum.find(checks, fn {_rule, ok?} -> not ok? end) do
      nil ->
        :ok

      {rule, false} ->
        {:error,
         Relay.Error.new(:invalid_content, "delivery_windows breaks a consistency rule", %{
           rule: rule
         })}
    end
  end

  # DS-18
  # DS-50
  @doc """
  Resolves the windows in force for a scope from the content of the installation version and of the tenant version (`nil` when the tenant has none): a tenant row replaces the installation row of the same channel and provider, every row is bounded as the module documentation says, and a channel without an installation default has no window. Returns the rows in channel and provider order.
  """
  @spec resolve(map(), map() | nil) :: [window()]
  def resolve(%{} = installation, tenant) do
    defaults =
      for row <- rows(installation), row["provider"] == nil, into: %{}, do: {row["channel"], row}

    keyed =
      Map.new(rows(installation) ++ rows(tenant || %{}), &{{&1["channel"], &1["provider"]}, &1})

    keyed
    |> Enum.sort()
    |> Enum.flat_map(fn {{channel, _provider}, row} ->
      case Map.fetch(defaults, channel) do
        {:ok, default} -> [bound(row, default)]
        :error -> []
      end
    end)
  end

  # DS-18
  @doc "Finds the window of a channel and provider among resolved windows: the provider's row, else the channel's, else `nil`."
  @spec window([window()], String.t(), String.t() | nil) :: window() | nil
  def window(windows, channel, provider) do
    Enum.find(windows, &(&1["channel"] == channel and &1["provider"] == provider)) ||
      Enum.find(windows, &(&1["channel"] == channel and &1["provider"] == nil))
  end

  # DS-18
  # INV-5
  @doc "The window stage of an accepted delivery at `now`: 0 inside the short window, 1 (`unknown_pending`) once the short window has passed, 2 (`unknown`) once the long window has passed."
  @spec stage(window(), DateTime.t(), DateTime.t()) :: stage()
  def stage(%{"short_ms" => short, "long_ms" => long}, %DateTime{} = accepted_at, now) do
    age = DateTime.diff(now, accepted_at, :millisecond)

    cond do
      age >= long -> 2
      age >= short -> 1
      true -> 0
    end
  end

  defp bound(row, default) do
    short =
      row["short_ms"]
      |> clamp(div(default["short_ms"], 2), default["short_ms"] * 2)
      |> clamp(@floor_ms, @ceiling_ms)

    long =
      row["long_ms"]
      |> clamp(div(default["long_ms"], 2), default["long_ms"] * 2)
      |> clamp(short, @ceiling_ms)

    %{
      "channel" => row["channel"],
      "provider" => row["provider"],
      "short_ms" => short,
      "long_ms" => long
    }
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  defp rows(content) do
    case Map.get(content, "windows") do
      rows when is_list(rows) -> rows
      _ -> []
    end
  end
end
