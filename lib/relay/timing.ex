defmodule Relay.Timing do
  @moduledoc """
  The tenant's control of the deterministic jitter (WF-42, WF-58). Two spreads apply: the release spread of deliveries deferred to the end of quiet hours, a weekly schedule, `dnd_until` or the PC-48 window (`timing.release_jitter_spread`, PT15M), and the scheduled spread of single scheduled jobs, a `send_at` and the timer of a recurrence occurrence (`timing.scheduled_jitter_spread`, PT60S).

  A tenant environment may only shrink the spreads, through its `timing.jitter` setting: `release_spread_ms` and `scheduled_spread_ms` from zero to their ceiling and `precision`, `jittered` or `strict`; `strict` zeroes both. A send's own `timing_precision: strict` zeroes them for that send. A missing or unreadable setting is the ceilings with `jittered`. The setting is read inside the caller's scoped transaction.
  """

  @key "timing.jitter"
  @release_ms Relay.Limits.seconds!(["timing", "release_jitter_spread"]) * 1000
  @scheduled_ms Relay.Limits.seconds!(["timing", "scheduled_jitter_spread"]) * 1000

  @type precision :: :jittered | :strict
  @type kind :: :release | :scheduled
  @type t :: %{
          release_spread_ms: non_neg_integer(),
          scheduled_spread_ms: non_neg_integer(),
          precision: precision()
        }

  @doc "The setting key of the tenant's jitter control."
  @spec key() :: String.t()
  def key, do: @key

  # WF-58
  @doc "The ceilings of the spreads in milliseconds."
  @spec ceilings() :: %{release_spread_ms: pos_integer(), scheduled_spread_ms: pos_integer()}
  def ceilings, do: %{release_spread_ms: @release_ms, scheduled_spread_ms: @scheduled_ms}

  # WF-58
  @doc "The control without a tenant setting: both ceilings, `jittered`."
  @spec default() :: t()
  def default,
    do: %{release_spread_ms: @release_ms, scheduled_spread_ms: @scheduled_ms, precision: :jittered}

  # WF-58
  @doc "Checks a stored value of the setting: an object of `release_spread_ms` (0 to the release ceiling), `scheduled_spread_ms` (0 to the scheduled ceiling) and `precision` (`jittered` or `strict`); `nil` clears. Returns the value or the names of the fields out of bounds."
  @spec cast(term()) :: {:ok, map() | nil} | {:error, [String.t()]}
  def cast(nil), do: {:ok, nil}

  def cast(%{"release_spread_ms" => release, "scheduled_spread_ms" => scheduled} = value)
      when map_size(value) == 3 do
    errors =
      [
        {"release_spread_ms", within?(release, @release_ms)},
        {"scheduled_spread_ms", within?(scheduled, @scheduled_ms)},
        {"precision", value["precision"] in ["jittered", "strict"]}
      ]
      |> Enum.reject(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))

    if errors == [], do: {:ok, value}, else: {:error, errors}
  end

  def cast(_value), do: {:error, ["release_spread_ms", "scheduled_spread_ms", "precision"]}

  # WF-58
  @doc "The control of a stored value; a missing or unreadable value is `default/0`."
  @spec from_stored(term()) :: t()
  def from_stored(value) do
    case cast(value) do
      {:ok, %{} = stored} ->
        %{
          release_spread_ms: stored["release_spread_ms"],
          scheduled_spread_ms: stored["scheduled_spread_ms"],
          precision: precision(stored["precision"])
        }

      _none ->
        default()
    end
  end

  # WF-58
  @doc "The stored value of a control."
  @spec to_stored(t()) :: map()
  def to_stored(%{} = control) do
    %{
      "release_spread_ms" => control.release_spread_ms,
      "scheduled_spread_ms" => control.scheduled_spread_ms,
      "precision" => Atom.to_string(control.precision)
    }
  end

  # WF-58
  @doc "Reads the tenant's control inside the caller's scoped transaction."
  @spec read() :: t()
  def read do
    case Relay.Repo.call!("relay_fn.setting_resolve", [nil, [@key]]) do
      [%{"value" => value} | _rest] -> from_stored(value)
      [] -> default()
    end
  end

  # WF-42
  # WF-58
  @doc "The spread of `kind` in milliseconds under the tenant's control and a send's own precision (`nil` for none); `strict` on either side is zero."
  @spec spread(t(), kind(), precision() | nil) :: non_neg_integer()
  def spread(_control, _kind, :strict), do: 0
  def spread(%{precision: :strict}, _kind, _send), do: 0
  def spread(%{release_spread_ms: ms}, :release, _send), do: ms
  def spread(%{scheduled_spread_ms: ms}, :scheduled, _send), do: ms

  @doc "The precision of its stored name; anything but `strict` is `jittered`."
  @spec precision(term()) :: precision()
  def precision("strict"), do: :strict
  def precision(_name), do: :jittered

  defp within?(ms, ceiling), do: is_integer(ms) and ms >= 0 and ms <= ceiling
end
