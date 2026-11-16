defmodule Relay.Devices.Signals do
  @moduledoc """
  The sync signals of a subscriber's mobile devices (IN-35, IN-38, IN-40, IN-52). A signal never carries inbox content: it tells the app to synchronise, with the counter version the change produced, and a read signal also names the notification read on another device so the shown notification can be removed.

  * iOS (`apns`): a background push whose payload is `{"aps": {"content-available": 1}, "relay": {"sync": true, "counter_version": n}}` and nothing else; the SDK removes a notification read elsewhere after it synchronises. Signals of one device are coalesced within `devices.sync_coalesce` (60 seconds): the first goes at once and the others of the window collapse into one trailing signal at its end. At most `devices.sync_per_hour_ios` (3) signals go to a device per hour; the excess is dropped and the sync on the next return to the foreground makes up for it (IN-21).
  * Android (`fcm`): a data message at normal priority with a time to live of `devices.sync_ttl_android` (60 seconds), collapsing under one key; a read signal carries the notification so the SDK cancels the shown one at once.
  * A device that holds an active realtime connection gets no signal; it receives the change on its connection (IN-40). Web Push and UnifiedPush have no silent message and get none.
  * When Valkey cannot answer for the coalescing window or the hourly count, the iOS signal is dropped: a signal is only a hint.

  Signals are sent by the job `Relay.Devices.SignalJob`, whose arguments carry the scope, identifiers and the counter version only (T-15), through the sender configured as `config :relay, Relay.Devices, signal_sender: Module` (by default `Relay.Channels.Live`, `c:Relay.Devices.send_signal/3`).
  """

  alias Relay.Devices.Connections
  alias Relay.Scope

  @coalesce_ms Relay.Limits.seconds!(["devices", "sync_coalesce"]) * 1_000
  @per_hour Relay.Limits.fetch!(["devices", "sync_per_hour_ios"])
  @android_ttl_s Relay.Limits.seconds!(["devices", "sync_ttl_android"])
  @hour_ms 3_600_000
  @platforms ["apns", "fcm"]
  @default_sender Relay.Channels.Live

  @type kind :: :sync | :read
  @type signal :: %{
          id: Relay.Id.t(),
          kind: kind(),
          counter_version: non_neg_integer() | nil,
          notification_id: Relay.Id.t() | nil,
          ttl_s: pos_integer() | nil
        }
  @type outcome :: :sent | :coalesced | :trailing | :dropped | :connected | :failed

  @doc "The platforms that receive sync signals."
  @spec platforms() :: [String.t(), ...]
  def platforms, do: @platforms

  # IN-35
  # IN-38
  # T-15
  @doc "The job arguments of a signal to the devices of a subscriber: `kind` (`:sync` or `:read`), the counter version of the counter write and, for `:read`, the notification read. `except_device_id` leaves out the device the change came from."
  @spec job_args(Scope.t(), Relay.Id.t(), kind(), map()) :: map()
  def job_args(%Scope{} = scope, subscriber_id, kind, attrs) when kind in [:sync, :read] do
    scope
    |> Scope.to_job_args()
    |> Map.merge(%{
      "subscriber_id" => Relay.Id.to_string(subscriber_id),
      "kind" => Atom.to_string(kind),
      "counter_version" => Map.get(attrs, :counter_version)
    })
    |> put_id("notification_id", Map.get(attrs, :notification_id))
    |> put_id("except_device_id", Map.get(attrs, :except_device_id))
  end

  defp put_id(args, _name, nil), do: args
  defp put_id(args, name, id), do: Map.put(args, name, Relay.Id.to_string(id))

  # IN-35
  # IN-38
  # IN-40
  # IN-52
  @doc "Sends a signal to the devices `targets` of a subscriber with the job's arguments; returns the outcome per device identifier."
  @spec run(Scope.t(), Relay.Id.t(), [map()], map()) :: %{Relay.Id.t() => outcome()}
  def run(%Scope{} = scope, subscriber_id, targets, args) do
    signal = signal(args)

    for target <- targets, wanted?(target, args), into: %{} do
      if Connections.connected?(scope, subscriber_id, target.id),
        do: {target.id, :connected},
        else: {target.id, deliver(scope, target, signal, args)}
    end
  end

  defp wanted?(target, args) do
    id = Relay.Id.to_string(target.id)

    target.platform in @platforms and args["except_device_id"] != id and
      args["device_id"] in [nil, id]
  end

  defp signal(args) do
    %{
      id: Relay.Id.generate(),
      kind: if(args["kind"] == "read", do: :read, else: :sync),
      counter_version: version(args["counter_version"]),
      notification_id: parse(args["notification_id"]),
      ttl_s: nil
    }
  end

  defp version(n) when is_integer(n) and n >= 0, do: n
  defp version(_n), do: nil

  defp parse(nil), do: nil

  defp parse(text) do
    case Relay.Id.parse(text) do
      {:ok, id} -> id
      {:error, _error} -> nil
    end
  end

  # IN-35
  # IN-52
  defp deliver(scope, %{platform: "fcm"} = target, signal, _args),
    do: send_signal(scope, target, %{signal | ttl_s: @android_ttl_s})

  defp deliver(scope, %{platform: "apns"} = target, signal, args) do
    case Relay.Platform.put_short_lived_new(scope, window_key(target), "1", @coalesce_ms) do
      {:ok, true} -> hourly(scope, target, signal)
      {:ok, false} -> trail(scope, target, args)
      {:error, _reason} -> :dropped
    end
  end

  # IN-52
  defp hourly(scope, target, signal) do
    member = Relay.Id.to_string(signal.id)
    path = ["sync_hour", Relay.Id.to_string(target.id)]

    case Relay.Platform.sliding_set_count(scope, path, @hour_ms, member, @per_hour) do
      {:ok, %{count: count}} when count < @per_hour ->
        _ = Relay.Platform.sliding_set_add(scope, path, @hour_ms, member)
        send_signal(scope, target, signal)

      _full_or_unavailable ->
        :dropped
    end
  end

  # IN-52
  defp trail(_scope, _target, %{"trailing" => true}), do: :coalesced

  defp trail(scope, target, args) do
    case Relay.Platform.put_short_lived_new(scope, trail_key(target), "1", @coalesce_ms) do
      {:ok, true} -> schedule(target, args)
      _taken_or_unavailable -> :coalesced
    end
  end

  defp schedule(target, args) do
    args = Map.merge(args, %{"device_id" => Relay.Id.to_string(target.id), "trailing" => true})
    at = DateTime.add(Relay.Clock.utc_now(), @coalesce_ms, :millisecond)

    case Oban.insert(Relay.Devices.SignalJob.new(args, scheduled_at: at)) do
      {:ok, _job} -> :trailing
      {:error, _reason} -> :dropped
    end
  end

  defp send_signal(scope, target, signal) do
    case sender().send_signal(scope, target, signal) do
      :ok -> :sent
      {:error, _reason} -> :failed
    end
  end

  defp window_key(target), do: ["sync_window", Relay.Id.to_string(target.id)]
  defp trail_key(target), do: ["sync_trail", Relay.Id.to_string(target.id)]

  defp sender do
    :relay
    |> Application.get_env(Relay.Devices, [])
    |> Keyword.get(:signal_sender, @default_sender)
  end
end
