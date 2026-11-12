defmodule Relay.Devices.Presence do
  @moduledoc """
  The device status channel (IN-47, IN-48, IN-53): short-lived status signals a recipient's device reports about itself, from the versioned dictionary `v1` of booleans `worn`, `locked`, `headphones`, `focus` and `break`.

  * A write carries only the keys that changed and a time to live, `PT5M` by default and cut at `PT15M` (`devices.status_ttl_default`, `devices.status_ttl_max`); each signal keeps its own expiry and an expired one is `unknown`. A device writes at most once per second (`devices.status_writes_per_second`); the next write in the same second is refused.
  * The record lives only on Valkey under the device's tenant key with a time to live; nothing reaches PostgreSQL, the inbox, the delivery ledger or the archive. When Valkey cannot be read every signal is `unknown`; a lost write only costs freshness.
  * A write answers whether it was a break transition (WF-56, IN-53): `break` becoming `true`, `focus` going from `true` to `false`, or `locked` going from `true` to `false`. An expiry is never a transition.
  * The values never reach a log line, a metric label, a trace, analytics, the tenant's server API or another recipient (IN-48); this module emits nothing.
  """

  @versions %{"v1" => ~w(break focus headphones locked worn)}
  @default_ttl_ms Relay.Limits.seconds!(["devices", "status_ttl_default"]) * 1_000
  @max_ttl_ms Relay.Limits.seconds!(["devices", "status_ttl_max"]) * 1_000
  @rate_ms div(1_000, Relay.Limits.fetch!(["devices", "status_writes_per_second"]))
  @record "status"
  @rate "status_rate"

  @type value :: boolean() | :unknown
  @type signals :: %{String.t() => value()}
  @type written :: %{break: boolean(), signals: signals()}
  @type previous :: %{String.t() => {boolean(), integer()} | boolean()}

  # IN-53
  @doc "The dictionary versions with their signal names."
  @spec versions() :: %{String.t() => [String.t()]}
  def versions, do: @versions

  # IN-53
  @doc "The signal names of a dictionary version, or `nil` for a version that does not exist."
  @spec signals(String.t()) :: [String.t()] | nil
  def signals(version), do: Map.get(@versions, version)

  # IN-53
  @doc "The default time to live of a signal, in milliseconds."
  @spec default_ttl_ms() :: pos_integer()
  def default_ttl_ms, do: @default_ttl_ms

  # IN-53
  @doc "The longest time to live of a signal, in milliseconds; a longer one is cut to it."
  @spec max_ttl_ms() :: pos_integer()
  def max_ttl_ms, do: @max_ttl_ms

  # IN-47
  # IN-53
  @doc "Writes the changed signals of a device with their time to live in milliseconds, cut at the ceiling. Answers the device's signals after the write and whether the write was a break transition; `{:error, :rate_limited}` for a second write within the device's interval and `{:error, :unavailable}` when Valkey cannot be reached."
  @spec write(Relay.Scope.t(), Relay.Id.t(), %{String.t() => boolean()}, pos_integer()) ::
          {:ok, written()} | {:error, :rate_limited | :unavailable}
  def write(%Relay.Scope{} = scope, device_id, changes, ttl_ms)
      when is_map(changes) and is_integer(ttl_ms) and ttl_ms > 0 do
    now = now_ms()

    with :ok <- admit(scope, device_id),
         {:ok, current} <- stored(scope, device_id, now) do
      until = now + min(ttl_ms, @max_ttl_ms)
      merged = merge(current, changes, until)
      ttl = Enum.reduce(merged, until, fn {_name, {_value, at}}, acc -> max(acc, at) end) - now

      case Relay.Platform.put_short_lived(scope, key(device_id), encode(merged), ttl) do
        :ok -> {:ok, %{break: break?(current, changes), signals: view(merged)}}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  # IN-47
  @doc "The current signals of a device; every signal is `:unknown` when it expired, was never written or Valkey cannot be read."
  @spec read(Relay.Scope.t(), Relay.Id.t()) :: signals()
  def read(%Relay.Scope{} = scope, device_id) do
    case stored(scope, device_id, now_ms()) do
      {:ok, current} -> view(current)
      {:error, :unavailable} -> view(%{})
    end
  end

  # WF-56
  # IN-53
  @doc "Whether changing `changes` over the unexpired `previous` values is a break transition: `break` to `true`, `focus` from `true` to `false` or `locked` from `true` to `false`."
  @spec break?(previous(), %{String.t() => boolean()}) :: boolean()
  def break?(previous, changes) do
    (changes["break"] == true and value(previous, "break") != true) or
      (changes["focus"] == false and value(previous, "focus") == true) or
      (changes["locked"] == false and value(previous, "locked") == true)
  end

  defp merge(current, changes, until) do
    Enum.reduce(changes, current, fn {name, value}, acc -> Map.put(acc, name, {value, until}) end)
  end

  defp value(previous, name) do
    case Map.get(previous, name) do
      {value, _until} -> value
      value -> value
    end
  end

  defp admit(scope, device_id) do
    case Relay.Platform.put_short_lived_new(scope, rate_key(device_id), "1", @rate_ms) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :rate_limited}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp stored(scope, device_id, now) do
    case Relay.Platform.get_short_lived(scope, key(device_id)) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, text} -> {:ok, decode(text, now)}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp view(current) do
    Map.new(Map.fetch!(@versions, "v1"), fn name ->
      case Map.get(current, name) do
        {value, _until} -> {name, value}
        nil -> {name, :unknown}
      end
    end)
  end

  defp encode(signals) do
    entries = Map.new(signals, fn {name, {value, until}} -> {name, [value, until]} end)
    Jason.encode!(%{"v" => "v1", "s" => entries})
  end

  defp decode(text, now) do
    known = Map.fetch!(@versions, "v1")

    case Jason.decode(text) do
      {:ok, %{"s" => %{} = entries}} ->
        for {name, [value, until]} <- entries,
            name in known and is_boolean(value) and is_integer(until) and until > now,
            into: %{},
            do: {name, {value, until}}

      _other ->
        %{}
    end
  end

  defp key(device_id), do: [@record, Relay.Id.to_string(device_id)]
  defp rate_key(device_id), do: [@rate, Relay.Id.to_string(device_id)]

  defp now_ms, do: DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)
end
