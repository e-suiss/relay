defmodule Relay.Api.Presence do
  @moduledoc """
  The device status channel of the subscriber API (IN-47, IN-48, IN-53): a device writes its own short-lived status signals with the `presence:write` scope, and the subscriber's own clients read a snapshot of every device. Writes go over REST only (IN-31).

  * A write names the dictionary `version` (`v1`), the changed `signals` and an optional `ttl` (`PT5M` by default, cut at `PT15M`). A signal outside the dictionary, or a value that is not a boolean, is `422 unknown_field`. A second write of the same device within a second is `429 rate_limited`.
  * The status lives on Valkey only: no idempotency record, ledger entry or database row holds it, so the write takes no `Idempotency-Key`; writing the same signals again is harmless. When Valkey cannot be reached the write is `503` and every signal reads `unknown`.
  * A write that is a break transition releases the subscriber's `next_break` deliveries (`Relay.Policy.Live.break_reached/2`, WF-56). The answer never says so: a status value or transition reaches no other surface (IN-48).
  """

  alias Relay.Api.Duration
  alias Relay.Api.Views

  @version "v1"

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # IN-47
  # IN-53
  # WF-56
  @doc "Writes the changed status signals of one of the token subscriber's own devices and answers with the device's status."
  @spec write(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t(), map()) :: answer()
  def write(scope, subscriber_id, device_id, body) do
    with {:ok, changes, ttl_ms} <- changes(body),
         {:ok, written} <- written(scope, subscriber_id, device_id, changes, ttl_ms) do
      _ = if written.break, do: Relay.Policy.Live.break_reached(scope, subscriber_id)
      {:ok, {200, [], view(device_id, written.signals)}}
    end
  end

  # IN-47
  @doc "The status of every device of the token subscriber that is not disabled."
  @spec read(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def read(scope, subscriber_id) do
    case Relay.Devices.status(scope, subscriber_id) do
      {:ok, devices} ->
        data = Enum.map(devices, &view(&1.device_id, &1.signals))
        {:ok, {200, [], %{"object" => "list", "data" => data}}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # IN-53
  defp changes(%{"version" => @version, "signals" => %{} = signals} = body) do
    known = Relay.Devices.status_signals(@version)

    unknown =
      for {name, value} <- Enum.sort(signals),
          name not in known or not is_boolean(value),
          do: %{pointer: "/signals/" <> name, code: "not_allowed", detail: "not in dictionary v1"}

    cond do
      unknown != [] ->
        message = "a signal is not in the dictionary"
        {:error, Relay.Error.new(:unknown_field, message, %{errors: unknown})}

      signals == %{} ->
        invalid("/signals", "too_short", "name at least one changed signal")

      true ->
        with {:ok, ttl_ms} <- ttl(Map.get(body, "ttl")), do: {:ok, signals, ttl_ms}
    end
  end

  defp changes(_body), do: invalid("/version", "unsupported_value", "the dictionary is v1")

  # IN-53
  defp ttl(nil), do: {:ok, Relay.Devices.status_ttl_ms().default}

  defp ttl(text) do
    case Duration.to_ms(text) do
      {:ok, ms} when ms >= 1_000 -> {:ok, min(ms, Relay.Devices.status_ttl_ms().max)}
      {:ok, _ms} -> invalid("/ttl", "too_short", "the time to live is at least one second")
      :error -> invalid("/ttl", "invalid_format", "an ISO 8601 duration")
    end
  end

  defp written(scope, subscriber_id, device_id, changes, ttl_ms) do
    case Relay.Devices.status_write(scope, subscriber_id, device_id, changes, ttl_ms) do
      {:ok, written} -> {:ok, written}
      {:error, :device_not_found} -> {:error, Relay.Api.Devices.device_not_found()}
      {:error, :rate_limited} -> {:error, rate_limited()}
      {:error, :unavailable} -> {:error, unavailable()}
    end
  end

  # IN-47
  defp view(device_id, signals) do
    %{
      "object" => "device_status",
      "device_id" => Views.id("dev", device_id),
      "version" => @version,
      "signals" => Map.new(signals, fn {name, value} -> {name, signal(value)} end)
    }
  end

  defp signal(:unknown), do: "unknown"
  defp signal(value) when is_boolean(value), do: value

  defp invalid(pointer, code, detail) do
    error = %{pointer: pointer, code: code, detail: detail}
    message = "the request breaks a field rule"
    {:error, Relay.Error.new(:validation_failed, message, %{errors: [error]})}
  end

  defp rate_limited do
    Relay.Error.new(:rate_limited, "a device writes its status at most once per second", %{
      retry_after: 1,
      limit: 1,
      actual: 2,
      limit_name: "devices.status_writes_per_second"
    })
  end

  defp unavailable do
    Relay.Error.new(:service_unavailable, "the device status is unavailable", %{retry_after: 1})
  end
end
