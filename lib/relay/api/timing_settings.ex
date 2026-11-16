defmodule Relay.Api.TimingSettings do
  @moduledoc """
  The tenant's jitter control in the server API (WF-42, WF-58, `Relay.Timing`): read the spreads in force, and replace them. The release spread (deliveries released at the end of quiet hours, a weekly schedule, `dnd_until` or the PC-48 window) is at most PT15M and the scheduled spread (a single `send_at` and a recurrence occurrence's timer) at most PT60S; the tenant may only shrink them, and `timing_precision: strict` zeroes both. A spread above its ceiling or that is not a whole-second duration is a field error, never clamped. A field left out of a replacement takes its ceiling, and `timing_precision` `jittered`. A change is audited as `setting.changed`.
  """

  alias Relay.Api.Duration
  alias Relay.Api.Gate
  alias Relay.TemplateStore
  alias Relay.Timing

  @fields [{"release_spread", :release_spread_ms}, {"scheduled_spread", :scheduled_spread_ms}]

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # WF-58
  @doc "The API view of a jitter control."
  @spec view(Timing.t()) :: map()
  def view(control) do
    ceilings = Timing.ceilings()

    %{
      "object" => "timing_settings",
      "release_spread" => iso(control.release_spread_ms),
      "scheduled_spread" => iso(control.scheduled_spread_ms),
      "timing_precision" => Atom.to_string(control.precision),
      "ceilings" => %{
        "release_spread" => iso(ceilings.release_spread_ms),
        "scheduled_spread" => iso(ceilings.scheduled_spread_ms)
      }
    }
  end

  # WF-58
  @doc "Reads the jitter control in force."
  @spec get(Relay.Scope.t()) :: answer()
  def get(scope) do
    case TemplateStore.in_scope(scope, fn _status -> Timing.read() end) do
      {:ok, control} -> {:ok, {200, [], view(control)}}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # WF-42
  # WF-58
  @doc "Replaces the jitter control inside the request's transaction."
  @spec put(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def put(scope, body, actor) do
    case spreads(body) do
      {spreads, []} ->
        control = Map.put(spreads, :precision, Timing.precision(body["timing_precision"]))
        key = Timing.key()
        digest = Gate.digest(scope, "setting.changed", key)
        _written = TemplateStore.tenant_setting_put(key, Timing.to_stored(control), digest, actor)
        {:ok, {200, [], view(control)}}

      {_spreads, errors} ->
        message = "the spreads break a field rule"
        {:error, Relay.Error.new(:validation_failed, message, %{errors: errors})}
    end
  end

  defp spreads(body) do
    ceilings = Timing.ceilings()

    Enum.reduce(@fields, {%{}, []}, fn {name, field}, acc ->
      add(acc, name, field, spread(Map.get(body, name), Map.fetch!(ceilings, field)))
    end)
  end

  defp add({spreads, errors}, _name, field, {:ok, ms}), do: {Map.put(spreads, field, ms), errors}

  defp add({spreads, errors}, name, _field, {:error, code, detail}),
    do: {spreads, errors ++ [error("/" <> name, code, detail)]}

  defp spread(nil, ceiling), do: {:ok, ceiling}

  defp spread(text, ceiling) do
    case Duration.to_ms(text) do
      {:ok, ms} when ms <= ceiling ->
        {:ok, ms}

      {:ok, _ms} ->
        {:error, "too_long", "a tenant may only shrink the spread, to at most #{iso(ceiling)}"}

      :error ->
        {:error, "invalid_format", "a spread is a duration of hours, minutes and seconds"}
    end
  end

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}

  defp iso(0), do: "PT0S"

  defp iso(ms) do
    seconds = div(ms, 1000)
    if rem(seconds, 60) == 0, do: "PT#{div(seconds, 60)}M", else: "PT#{seconds}S"
  end
end
