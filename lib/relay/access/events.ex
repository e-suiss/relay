defmodule Relay.Access.Events do
  @moduledoc """
  Access lifecycle events (`POST /v1/access/events`, S-110). A delivery is verified with the shared Suiss webhook profile under the keys of the link, its CloudEvents `id` must equal `webhook-id`, and its receipt commits with the job that processes it before the delivery is acknowledged; a repeated `webhook-id` is acknowledged and not processed again (S-69). Only the fields Relay needs cross the boundary: the receipt keeps the event's mapping fields and nothing else, and an event type Relay does not consume keeps none (E-70).

  `process/1` (the `Relay.Access.EventConsumer` job) applies a receipt by its type:

  * `tenant.created` creates the mapped tenant with its keys; the default time zone and locale are mandatory (TN-2, X-35) and another region is refused (INV-41).
  * `organization.created` and `organization.updated` create, rename or archive the mapped sub-tenant in both environments under one identifier (TN-6, C-12).
  * `api_client.created`, `api_client.updated`, `api_client.suspended`, `api_client.reactivated` and `api_client.revoked` write the API client trace and announce the new generation to every node (API-44, TN-24).
  * `user.suspended`, `user.reactivated` and `user.deleted` go to the configured user event handlers (`config :relay, Relay.Access, user_handlers: [module]`, `Relay.Access.UserHandler`); without one the receipt waits as `deferred` with reason `no_handler`.

  A receipt whose tenant, sub-tenant or client does not exist yet is `deferred` and queued again when a later event of the same Access tenant is applied; anything else that cannot apply is `rejected` with a reason.
  """

  require Logger

  alias Relay.Access.Clients
  alias Relay.Access.ClientStore
  alias Relay.Access.EventConsumer
  alias Relay.Access.EventStore
  alias Relay.Access.Link
  alias Relay.Access.Webhook
  alias Relay.Scope

  @mapping %{
    "tenant.created" => ~w(access_tenant_id region default_timezone default_locale sector),
    "organization.created" => ~w(access_tenant_id access_organization_id name),
    "organization.updated" => ~w(access_tenant_id access_organization_id name state),
    "api_client.created" =>
      ~w(access_tenant_id access_client_id environment access_organization_id scopes),
    "api_client.updated" => ~w(access_tenant_id access_client_id scopes),
    "api_client.suspended" => ~w(access_tenant_id access_client_id),
    "api_client.reactivated" => ~w(access_tenant_id access_client_id),
    "api_client.revoked" => ~w(access_tenant_id access_client_id),
    "user.suspended" => ~w(subject),
    "user.reactivated" => ~w(subject),
    "user.deleted" => ~w(subject)
  }
  @statuses %{
    "api_client.suspended" => "suspended",
    "api_client.reactivated" => "active",
    "api_client.revoked" => "revoked"
  }
  @users %{
    "user.suspended" => :suspended,
    "user.reactivated" => :reactivated,
    "user.deleted" => :deleted
  }
  @scopes ~w(publish read subscribers config kill_switch)
  @requeue_after ~w(tenant.created organization.created organization.updated api_client.created)
  @batch 100

  @type outcome :: :processed | {:deferred, String.t()} | {:rejected, String.t()}

  # E-36
  # E-70
  # E-78
  @doc "Receives a delivery: `request` carries the webhook headers, the raw body and the decoded envelope."
  @spec accept(map()) :: :ok | {:error, Relay.Error.t()}
  def accept(request) do
    now = DateTime.to_unix(Relay.Clock.utc_now())

    with {:ok, keys} <- keys(),
         :ok <- Webhook.verify(request, keys, now),
         :ok <- same_id(request) do
      record(request)
    end
  end

  # INV-41
  # TN-57
  defp keys do
    case Link.current() do
      %{state: state, keys: [_ | _] = keys} when state in [:ok, :stale] -> {:ok, keys}
      _other -> {:error, Relay.Error.new(:service_unavailable, "no Access link")}
    end
  end

  defp same_id(%{webhook_id: id, envelope: %{"id" => id}}), do: :ok

  defp same_id(_request) do
    {:error,
     Relay.Error.new(:validation_failed, "the event id must equal webhook-id", %{
       errors: [%{pointer: "/id", code: "conflict"}]
     })}
  end

  defp record(%{envelope: envelope} = request) do
    type = envelope["type"]
    payload = minimal(type, envelope["data"])

    attrs = %{
      id: Relay.Id.generate(),
      webhook_id: request.webhook_id,
      event_type: type,
      access_tenant_id: text(payload["access_tenant_id"], 128),
      payload: payload,
      body_digest: :crypto.hash(:sha256, request.raw_body),
      traceparent: envelope["traceparent"]
    }

    case EventStore.record(attrs, &job/1) do
      {:ok, _recorded_or_duplicate} -> :ok
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "not recorded")}
    end
  end

  # E-70
  @doc "The fields of an event's data that cross the boundary; an unknown type keeps none."
  @spec minimal(String.t(), term()) :: map()
  def minimal(type, data) when is_map(data), do: Map.take(data, Map.get(@mapping, type, []))
  def minimal(_type, _data), do: %{}

  @doc "The Access event types Relay consumes."
  @spec types() :: [String.t()]
  def types, do: @mapping |> Map.keys() |> Enum.sort()

  defp job(id), do: EventConsumer.new(%{"receipt_id" => Relay.Id.to_string(id)})

  # E-36
  @doc "Applies a receipt and marks it; a transient failure is returned so that the job retries."
  @spec process(Relay.Id.t()) :: :ok | {:error, term()}
  def process(id) do
    case EventStore.read(id) do
      %{state: state} = receipt when state in ["received", "deferred"] -> apply_receipt(receipt)
      _final_or_missing -> :ok
    end
  end

  defp apply_receipt(receipt) do
    case handle(receipt.event_type, receipt.payload, receipt) do
      :processed ->
        _ = EventStore.mark(receipt.id, :processed, nil)
        if receipt.event_type in @requeue_after, do: requeue(receipt.access_tenant_id, nil)
        :ok

      {state, reason} when state in [:deferred, :rejected] ->
        _ = EventStore.mark(receipt.id, state, reason)
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  # E-36
  @doc "Queues the deferred receipts of an Access tenant, or those deferred for `reason`, again."
  @spec requeue(String.t() | nil, String.t() | nil) :: :ok
  def requeue(access_tenant_id, reason) do
    access_tenant_id
    |> EventStore.deferred(reason, @batch)
    |> Enum.map(&job/1)
    |> EventStore.enqueue_all()
  end

  defp handle("tenant.created", payload, receipt), do: tenant_created(payload, receipt)

  defp handle("organization." <> _ = type, payload, receipt),
    do: with_tenant(payload, &organization(type, payload, receipt, &1))

  defp handle("api_client.created", payload, receipt),
    do: with_tenant(payload, &client_created(payload, receipt, &1))

  defp handle("api_client.updated", payload, receipt),
    do: with_client(payload, &client_updated(payload, receipt, &1))

  defp handle("api_client." <> _ = type, payload, receipt) when is_map_key(@statuses, type),
    do: with_client(payload, &client_status(type, payload, receipt, &1))

  defp handle("user." <> _ = type, payload, receipt) when is_map_key(@users, type),
    do: user(Map.fetch!(@users, type), payload, receipt)

  defp handle(_type, _payload, _receipt), do: {:rejected, "unsupported_type"}

  # TN-1
  # TN-2
  # X-35
  # INV-41
  defp tenant_created(payload, receipt) do
    with {:ok, region} <- Relay.Region.cast(payload["region"]),
         tenant when is_binary(tenant) <- text(payload["access_tenant_id"], 128),
         timezone when is_binary(timezone) <- payload["default_timezone"],
         locale when is_binary(locale) <- payload["default_locale"] do
      id = Relay.Id.generate()

      attrs = %{
        id: id,
        access_tenant_id: tenant,
        region: region,
        sector: payload["sector"] || "general",
        default_timezone: timezone,
        default_locale: locale,
        record_digest: digest(receipt, "tenant")
      }

      provision(attrs, receipt)
    else
      {:error, %Relay.Error{code: :invalid_region}} -> {:rejected, "region_mismatch"}
      _missing -> {:rejected, "defaults_missing"}
    end
  end

  defp provision(attrs, receipt) do
    case Relay.Tenancy.Provisioning.create_tenant(attrs, actor(receipt)) do
      {result, _id} when result in [:created, :exists] ->
        :processed

      {:region_mismatch, _id} ->
        {:rejected, "region_mismatch"}

      {:conflict, _id} ->
        {:rejected, "conflict"}

      {:error, %Relay.Error{code: code}} when code in [:invalid_time_zone, :invalid_locale] ->
        {:rejected, "invalid_defaults"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp with_tenant(payload, fun) do
    case ClientStore.tenant(to_string(payload["access_tenant_id"])) do
      %{id: id} -> fun.(id)
      nil -> {:deferred, "unknown_tenant"}
    end
  end

  # TN-6
  # C-12
  defp organization(type, payload, receipt, tenant_id) do
    organization_id = payload["access_organization_id"]
    scopes = Enum.map(Relay.Environment.all(), &Scope.new!(tenant_id, &1))

    with {:ok, existing} <- existing_subtenant(scopes, organization_id) do
      if type == "organization.updated" and payload["state"] == "archived",
        do: archive(scopes, existing, receipt),
        else: upsert_subtenant(scopes, existing, payload, receipt)
    end
  end

  defp existing_subtenant(scopes, organization_id) do
    Enum.reduce_while(scopes, {:ok, nil}, fn scope, acc ->
      case subtenant_in(scope, organization_id) do
        {:ok, nil} -> {:cont, acc}
        {:ok, subtenant} -> {:halt, {:ok, subtenant}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp subtenant_in(scope, organization_id),
    do: ClientStore.in_scope(scope, fn _status -> ClientStore.subtenant(organization_id) end)

  defp upsert_subtenant(scopes, existing, payload, receipt) do
    case payload["name"] || (existing && existing.name) do
      name when is_binary(name) ->
        attrs = %{
          id: (existing && existing.id) || Relay.Id.generate(),
          access_organization_id: payload["access_organization_id"],
          name: name,
          record_digest: digest(receipt, "subtenant")
        }

        each(scopes, &Relay.Tenancy.upsert_subtenant(&1, attrs, actor(receipt)))

      _missing ->
        {:rejected, "name_missing"}
    end
  end

  defp archive(_scopes, nil, _receipt), do: :processed

  defp archive(scopes, existing, receipt) do
    digest = digest(receipt, "subtenant")
    each(scopes, &Relay.Tenancy.archive_subtenant(&1, existing.id, digest, actor(receipt)))
  end

  defp each(scopes, fun) do
    Enum.reduce_while(scopes, :processed, fn scope, acc ->
      case fun.(scope) do
        {:ok, _result} -> {:cont, acc}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # API-42
  # API-44
  # TN-24
  defp client_created(payload, receipt, tenant_id) do
    with {:ok, environment} <- Relay.Environment.cast(payload["environment"]),
         {:ok, scopes} <- scopes(payload["scopes"]),
         scope = Scope.new!(tenant_id, environment),
         {:ok, subtenant_id} <- client_subtenant(scope, payload["access_organization_id"]) do
      attrs = %{
        id: Relay.Id.generate(),
        access_client_id: to_string(payload["access_client_id"]),
        subtenant_id: subtenant_id,
        scopes: scopes,
        access_event_ref: receipt.webhook_id
      }

      upsert_client(scope, attrs, receipt)
    else
      {:error, %Relay.Error{code: :invalid_environment}} -> {:rejected, "invalid_environment"}
      {:error, %Relay.Error{} = error} -> {:error, error}
      other -> other
    end
  end

  defp client_subtenant(_scope, nil), do: {:ok, nil}

  defp client_subtenant(scope, organization_id) do
    case subtenant_in(scope, organization_id) do
      {:ok, %{id: id}} -> {:ok, id}
      {:ok, nil} -> {:deferred, "subtenant_not_found"}
      {:error, error} -> {:error, error}
    end
  end

  defp scopes(scopes) when is_list(scopes) do
    if scopes != [] and Enum.all?(scopes, &(&1 in @scopes)),
      do: {:ok, Enum.uniq(scopes)},
      else: {:rejected, "invalid_scopes"}
  end

  defp scopes(_scopes), do: {:rejected, "invalid_scopes"}

  defp upsert_client(scope, attrs, receipt) do
    digest = digest(receipt, "api_client")
    work = fn _status -> ClientStore.upsert(attrs, digest, actor(receipt)) end

    case ClientStore.in_scope(scope, work) do
      {:ok, {result, _id, generation}} when result in [:created, :updated] ->
        announce(generation)

      {:ok, {result, _id, _generation}} when result in [:unchanged, :revoked_terminal] ->
        :processed

      {:ok, {:subtenant_not_found, _id, _generation}} ->
        {:deferred, "subtenant_not_found"}

      {:ok, {:subtenant_changed, _id, _generation}} ->
        Logger.error("Access names another sub-tenant for an API client; not applied",
          access_client_id: attrs.access_client_id
        )

        {:rejected, "subtenant_changed"}

      {:error, error} ->
        {:error, error}
    end
  end

  defp with_client(payload, fun) do
    access_tenant_id = to_string(payload["access_tenant_id"])

    case ClientStore.resolve(access_tenant_id, to_string(payload["access_client_id"])) do
      [resolved] -> fun.(resolved)
      _none -> {:deferred, "unknown_client"}
    end
  end

  defp client_updated(payload, receipt, resolved) do
    with {:ok, scopes} <- scopes(payload["scopes"]) do
      attrs = %{
        id: Relay.Id.generate(),
        access_client_id: to_string(payload["access_client_id"]),
        subtenant_id: resolved.subtenant_id,
        scopes: scopes,
        access_event_ref: receipt.webhook_id
      }

      upsert_client(scope(resolved), attrs, receipt)
    end
  end

  # API-44
  # TN-24 (5)
  # TN-36
  defp client_status(type, payload, receipt, resolved) do
    client = to_string(payload["access_client_id"])
    status = Map.fetch!(@statuses, type)
    digest = digest(receipt, "api_client")

    work = fn _status ->
      ClientStore.set_status(client, status, receipt.webhook_id, digest, actor(receipt))
    end

    case ClientStore.in_scope(scope(resolved), work) do
      {:ok, {:changed, generation}} -> announce(generation)
      {:ok, {:not_found, _generation}} -> {:deferred, "unknown_client"}
      {:ok, {_unchanged_or_invalid, _generation}} -> :processed
      {:error, error} -> {:error, error}
    end
  end

  defp scope(resolved), do: Scope.new!(resolved.tenant_id, resolved.environment)

  # API-44
  # TN-24 (5)
  # TN-36
  defp announce(generation) do
    :ok = Clients.advance(generation)
    _ = Relay.Platform.publish_signal(Clients.topic(), generation)
    :processed
  end

  # TN-20
  defp user(kind, payload, receipt) do
    case Keyword.get(Relay.Access.config(), :user_handlers, []) do
      [] ->
        {:deferred, "no_handler"}

      handlers ->
        subject = to_string(payload["subject"])
        results = Enum.map(handlers, & &1.handle_user_event(kind, subject, receipt.webhook_id))

        case Enum.find(results, &(&1 != :ok)) do
          nil -> :processed
          {:error, error} -> {:error, error}
          other -> {:error, other}
        end
    end
  end

  defp actor(receipt) do
    {:ok, actor} = Relay.Actor.new(:access, "access", "access", receipt.webhook_id)
    actor
  end

  defp digest(receipt, target) do
    canonical = Relay.Canonical.encode!(["relay.access_event.v1", receipt.webhook_id, target])
    :crypto.hash(:sha256, canonical)
  end

  defp text(value, max) when is_binary(value) and byte_size(value) <= max, do: value
  defp text(_value, _max), do: nil
end
