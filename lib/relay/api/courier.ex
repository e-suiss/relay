defmodule Relay.Api.Courier do
  @moduledoc """
  Access's own messages on the send entry (E-108, E-109, E-10, E-12). A CloudEvent whose type is in Access's `relay.message.*.v1` namespace, sent with the credential of the Access platform tenant, does not go through the tenant's type mapping: it is checked against Access's message schema (the exact copy in `contracts/access/`), its `source` must name the environment of its `accessenvironment` attribute, and that environment must be one of the environments of its `accesstenant` in the tenant snapshot (E-103). Relay answers `422` only for an event that can never be taken (the schema, the source, an environment the tenant does not have, an address of the wrong kind, a device recipient Relay cannot route); a tenant Relay does not know yet, an Access that cannot answer and a workflow still being published are `503` with `Retry-After`, so Access keeps the message. The CloudEvent `id` is the idempotency key and, with the `source`, the dedup key.

    * A delivered type is met by its protected workflow and template (`Relay.Api.Courier.Catalog`, written on first use by `Relay.Api.Courier.Provision`). The recipient set is the one recipient Access names (E-12): an inline e-mail address or phone number is a transient recipient (`Relay.Subscribers.prepare/4` with `transient: true`), whose address is sealed like any address and which never becomes a subscriber profile. The request is narrowed to the channel of the address, and a message that carries a sign-in or verification secret names the security subtype of that channel, so its rendered content is never stored (INV-22, INV-26). Its `expires_at` is the message's own when it has one (E-13).
    * `relay.message.iys_consent.v1` is the İYS channel of E-21 (E-109): the consent is written to İYS through Relay's own write path for the tenant `accesstenant` names, with that tenant's own brand, and is never written to the consent copy (E-80 stays its source). When the record cannot be written at all (the tenant entered no İYS configuration) its `failed` report to Access is queued at once; otherwise the report follows the upload's settlement (`Relay.Access.IysReport`).
  """

  alias Relay.Api.Courier.Catalog
  alias Relay.Api.Courier.Provision
  alias Relay.Api.Events
  alias Relay.Api.Schema
  alias Relay.Api.Store

  @source "urn:suiss:access:environment:"
  @kinds ~w(email phone device)
  @channels %{"email" => "email", "phone" => "sms", "device" => "push"}
  @iys_channels %{
    "sms" => {"sms", "phone"},
    "email" => {"email", "email"},
    "call" => {"voice", "phone"}
  }
  @iys_sources %{"self_service" => "web", "app" => "app"}
  @root JSV.build!(Catalog.schema())

  @type outcome ::
          :not_courier
          | {:ok, Events.prepared()}
          | {:ok, {:iys, map()}}
          | {:error, Relay.Error.t()}

  # E-108
  # E-109
  @doc "Takes a CloudEvent of Access's message namespace for the Access platform tenant: the prepared native event of a delivered type, `{:iys, body}` once an İYS consent record was handed to the write path (refused with `iys: false`, as in a batch), or `:not_courier` for any other event or tenant. Runs outside any transaction."
  @spec prepare(Events.context(), map(), keyword()) :: outcome()
  def prepare(%{scope: scope} = ctx, event, opts \\ []) do
    if is_map(event) and Catalog.courier_type?(event["type"]) and platform?(scope),
      do: take(ctx, event, Keyword.get(opts, :iys, true)),
      else: :not_courier
  end

  defp platform?(scope) do
    case Relay.Ingest.in_event_scope(scope, fn _status -> Relay.Ingest.platform_product() end) do
      {:ok, "access"} -> true
      _other -> false
    end
  end

  defp take(ctx, event, iys?) do
    with :ok <- Schema.validate(@root, Map.drop(event, ["traceparent", "tracestate"])),
         {:ok, environment} <- environment(event),
         {:ok, tenant} <- tenant(event["accesstenant"], environment) do
      case Catalog.lookup(event["type"]) do
        {:deliver, entry} -> deliver(ctx, event, entry)
        :iys when iys? -> iys(ctx.scope, event, tenant, environment)
        :iys -> invalid("/type", "not_allowed", "an İYS consent record is sent on its own")
        :unknown -> {:error, Relay.Error.new(:event_type_not_mapped, "no mapping for this type")}
      end
    end
  end


  # E-108
  defp environment(%{"source" => source, "accessenvironment" => environment}) do
    environment = String.downcase(environment)

    if String.downcase(source) == @source <> environment,
      do: {:ok, environment},
      else: invalid("/source", "conflict", "the source names another environment")
  end

  # E-108
  # E-103
  defp tenant(access_tenant, environment) do
    with {:tenant, %{status: "active"} = tenant} <-
           {:tenant, Relay.Access.mapped_tenant(access_tenant)},
         {:ok, true} <- Relay.Access.access_environment?(access_tenant, environment) do
      {:ok, Map.put(tenant, :access_tenant, access_tenant)}
    else
      {:tenant, nil} -> {:error, waiting("the Access tenant is not known to Relay yet")}
      {:tenant, _inactive} -> {:error, waiting("the Access tenant is not active in Relay")}
      {:ok, false} -> invalid("/accessenvironment", "not_found", "not the tenant's environment")
      {:ok, :unknown} -> {:error, waiting("Access does not know the tenant")}
      {:error, error} -> {:error, error}
    end
  end

  # E-108
  # E-12
  # INV-22
  defp deliver(ctx, event, entry) do
    data = event["data"]

    with {:ok, kind, address} <- recipient(data["recipient"]),
         :ok <- routable(kind),
         :ok <- Provision.ensure(ctx.scope, entry),
         {:ok, external_id} <- transient_id(ctx.scope, kind, address) do
      native =
        %{
          "workflow" => entry.key,
          "to" => [recipient_object(external_id, kind, address, data["locale"])],
          "data" => Map.take(data, Catalog.data_fields(entry.type)),
          "channels" => [Map.fetch!(@channels, kind)]
        }
        |> put_present("expires_at", data["expires_at"])
        |> put_present("security_subtype", Catalog.subtype(entry, kind))

      case Schema.validate_request("createEvent", "application/json", native) do
        :ok -> native_event(ctx, event, native)
        {:error, error} -> {:error, error}
      end
    end
  end

  defp native_event(ctx, event, native) do
    Events.prepare(Map.put(ctx, :transient, true), native,
      source: :cloudevents,
      cloudevent: Map.drop(event, ["accesstenant", "accessenvironment"]),
      dedup_key: Relay.Access.dedup_key(event["source"], event["id"])
    )
  end

  defp recipient(%{} = recipient) do
    case Enum.filter(@kinds, &is_binary(recipient[&1])) do
      [kind] -> {:ok, kind, recipient[kind]}
      _other -> invalid("/data/recipient", "invalid_format", "one address is required")
    end
  end

  defp recipient(_recipient),
    do: invalid("/data/recipient", "required", "one address is required")

  # E-108
  defp routable("device") do
    detail = "no device of this key thumbprint is registered with Relay"
    error = %{pointer: "/data/recipient/device", code: "not_found", detail: detail}
    {:error, Relay.Error.new(:recipient_not_found, "the device is unknown", %{errors: [error]})}
  end

  defp routable(_kind), do: :ok

  # E-108
  defp transient_id(scope, kind, address) do
    value = kind <> ":" <> normal(kind, address)
    target = %{tenant_id: scope.tenant_id, environment: scope.environment, purpose: "transient"}

    case Relay.Tenancy.blind_index(target, value) do
      {:ok, {_key_id, digest}} -> {:ok, "access-" <> Base.encode16(digest, case: :lower)}
      {:error, _reason} -> {:error, waiting("the recipient could not be prepared")}
    end
  end

  defp normal("email", address), do: String.downcase(String.trim(address))
  defp normal(_phone, address), do: String.trim(address)

  defp recipient_object(external_id, kind, address, locale) do
    put_present(%{"id" => external_id, kind => normal(kind, address)}, "locale", locale(locale))
  end

  # TP-25
  defp locale(tag) when is_binary(tag) do
    case tag |> String.downcase() |> String.split(["-", "_"]) do
      ["tr" | _rest] -> "tr"
      _other -> "en"
    end
  end

  defp locale(_none), do: nil

  # E-109
  # E-20
  # E-21
  defp iys(scope, event, tenant, environment) do
    data = event["data"]

    with {:ok, channel, address} <- iys_address(data),
         {:ok, consent_at} <- consent_at(data["consent_at"]),
         target = Relay.Scope.new!(tenant.id, scope.environment),
         movement = iys_movement(event, data, {channel, address}, consent_at),
         {:ok, written} <- iys_write(target, movement),
         :ok <- iys_unwritten(target, written, event, environment) do
      body = %{"object" => "iys_consent_record", "id" => event["id"], "status" => "accepted"}
      {:ok, {:iys, body}}
    end
  end

  defp iys_address(%{"channel" => channel, "recipient" => recipient}) do
    {relay_channel, kind} = Map.fetch!(@iys_channels, channel)

    case recipient do
      %{^kind => address} when is_binary(address) and map_size(recipient) == 1 ->
        {:ok, relay_channel, normal(kind, address)}

      _other ->
        invalid("/data/recipient", "conflict", "the address does not match the channel")
    end
  end

  defp consent_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> invalid("/data/consent_at", "invalid_format", "not an RFC 3339 time")
    end
  end

  defp consent_at(_none), do: invalid("/data/consent_at", "required", "the consent time")

  defp iys_movement(event, data, {channel, address}, consent_at) do
    %{
      channel: channel,
      status: if(data["consent"] == "approved", do: :approval, else: :rejection),
      address: address,
      source: Map.get(@iys_sources, data["source"], data["source"]),
      occurred_at: consent_at,
      origin: :access,
      recipient_type: data["recipient_type"],
      brand_subtenant_id: nil,
      access_record: String.downcase(event["id"]),
      access_environment: String.downcase(event["accessenvironment"])
    }
  end

  defp iys_write(target, movement) do
    case Relay.Iys.write(target, movement) do
      {:ok, written} -> {:ok, written}
      {:error, _reason} -> {:error, waiting("the İYS write path is unavailable")}
    end
  end

  # E-109
  defp iys_unwritten(target, written, event, environment)
       when written in [:not_configured, :out_of_scope] do
    report = %{
      "record" => String.downcase(event["id"]),
      "access_environment" => environment,
      "status" => "failed",
      "reason" => Atom.to_string(written),
      "at" => DateTime.to_unix(Relay.Clock.utc_now(), :millisecond)
    }

    queue = fn _status -> Relay.Access.queue_iys_report(target, report) end

    case Store.in_scope(target, queue) do
      {:ok, :ok} -> :ok
      _failed -> {:error, waiting("the İYS report could not be queued")}
    end
  end

  defp iys_unwritten(_target, _written, _event, _environment), do: :ok

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp invalid(pointer, code, detail) do
    error = %{pointer: pointer, code: code, detail: detail}
    message = "the Access message is invalid"
    {:error, Relay.Error.new(:validation_failed, message, %{errors: [error]})}
  end

  defp waiting(message), do: Relay.Error.new(:service_unavailable, message, %{retry_after: 30})
end
