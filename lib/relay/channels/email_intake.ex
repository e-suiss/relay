defmodule Relay.Channels.EmailIntake do
  @moduledoc """
  The intake of verified provider e-mail events (CH-39, CH-40, CH-47, DS-10). A webhook handler or the SES queue reader verifies the request or the SNS envelope first and passes the parsed events here (`Relay.Channels.email_events/2`). Each event of a known delivery is classified and planned (`Relay.Channels.email_event_plan/3`, against the active `email_bounce_codes` version) and recorded through the channel step's entry point, `Relay.Channels.Live.record_event/2`, with its evidence code and the provider code `event:<code>`, so the ledger, the projection and the unknown code alarm follow the declared evidence rows (CH-8).

  A hard bounce and a complaint suppress the recipient's address at once and without end, in the tenant's own suppression list (CH-40, PC-59); a `sender_config` result never suppresses (CH-39) and is reported as `[:relay, :channels, :email, :sender_config]` telemetry with the provider. A soft bounce is recorded but not yet counted toward a timed suppression, and the reputation counters are reported as `[:relay, :channels, :email, :reputation]` telemetry and counted in the sending domain's reputation circuit (`Relay.EmailReputation`, CH-87), by the domain the delivery was sent from; the soft bounce count needs the per-address state the circuit does not keep. An event that names no delivery, or a delivery Relay does not know, is skipped.
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Channels,
      Relay.Channels.Live,
      Relay.Datasets,
      Relay.EmailReputation,
      Relay.Preferences
    ],
    exports: []

  alias Relay.Scope

  @type outcome ::
          {:recorded, atom(), [term()]}
          | {:skipped, :no_delivery | :delivery_not_found | :unknown_event | :no_classification}
          | {:error, term()}

  # CH-39
  # CH-40
  # CH-47
  # DS-10
  @doc "Records the events of one verified provider payload in `scope` and applies their suppressions; returns one outcome per event."
  @spec ingest(Scope.t(), [map()]) ::
          {:ok, [outcome()]} | {:error, term()}
  def ingest(%Scope{} = scope, events) when is_list(events) do
    with {:ok, declarations} <- Relay.Datasets.channel_declarations(),
         {:ok, {table, _ref}} <- table() do
      {:ok, Enum.map(events, &one(scope, declarations, table, &1))}
    end
  end

  defp table do
    Relay.Datasets.decide(Relay.Datasets.installation_scope(), "email_bounce_codes", & &1)
  end

  defp one(_scope, _declarations, _table, %{delivery_id: nil}), do: {:skipped, :no_delivery}

  defp one(scope, declarations, table, event) do
    case Relay.Channels.email_event_plan(declarations, event, table) do
      {_result, []} -> {:skipped, :no_classification}
      {_result, actions} -> record(scope, event, actions)
    end
  end

  defp record(scope, event, actions) do
    code = Enum.find_value(actions, fn action -> evidence(action) end)

    fields = %{
      delivery_id: event.delivery_id,
      provider: event.provider,
      channel: "email",
      event_code: code,
      actor: :provider_webhook,
      raw_code: raw_code(code, event),
      detail: detail(event)
    }

    fields =
      if event.occurred_at, do: Map.put(fields, :occurred_at, event.occurred_at), else: fields

    case Relay.Channels.Live.record_event(scope, fields) do
      {:ok, recorded} ->
        Enum.each(actions, &apply_action(scope, event, &1))
        {:recorded, recorded.result, actions}

      {:error, reason} when reason in [:delivery_not_found, :unknown_event] ->
        {:skipped, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evidence({:evidence, code}), do: code
  defp evidence(_action), do: nil

  defp raw_code("delivered", _event), do: nil
  defp raw_code(_code, event), do: String.slice("event:" <> event.code, 0, 128)

  defp detail(event) do
    %{"status" => event.status, "provider_message_id" => event.provider_message_id}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # CH-40
  # PC-59
  defp apply_action(scope, %{recipient: recipient} = event, {:suppress, reason, nil})
       when recipient != nil do
    address = Relay.Redacted.expose(recipient)

    with {:ok, digests} <- Relay.Preferences.address_digests(scope, "email", address) do
      attrs = %{channel: "email", digests: digests, reason: reason, expires_at: nil}
      actor = provider_actor(event)

      Relay.Preferences.in_scope(scope, fn _status ->
        Relay.Preferences.add_suppression(scope, attrs, actor)
      end)
    end
  end

  # CH-39
  defp apply_action(_scope, event, {:sender_config, rule}) do
    :telemetry.execute([:relay, :channels, :email, :sender_config], %{count: 1}, %{
      provider: event.provider,
      rule: rule
    })
  end

  # CH-41
  # CH-87
  defp apply_action(scope, event, {:reputation, counter}) do
    :telemetry.execute([:relay, :channels, :email, :reputation], %{count: 1}, %{
      provider: event.provider,
      counter: counter
    })

    case Relay.EmailReputation.domain_of(scope, event.delivery_id) do
      {:ok, domain} when is_binary(domain) -> Relay.EmailReputation.count(scope, domain, counter)
      _unknown -> :ok
    end
  end

  defp apply_action(_scope, _event, _action), do: :ok

  defp provider_actor(event) do
    ref = "provider:" <> event.provider
    {:ok, actor} = Relay.Actor.new(:system, ref, ref)
    actor
  end
end
