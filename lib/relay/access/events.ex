defmodule Relay.Access.Events do
  @moduledoc """
  Access lifecycle events (`POST /v1/access/events`, S-110), pushed by Access as Security Event Tokens (E-94, `Relay.Access.SecurityEvent`): a SET is verified under the keys of the link, its `jti` is the event identifier, and its receipt commits with the job that processes it before the delivery is acknowledged; a repeated `jti` is acknowledged and not processed again (S-69). A key the link does not hold refreshes the keys once. Only the fields Relay needs cross the boundary: the receipt keeps the event's mapping fields and nothing else, and an event type Relay does not consume keeps none (E-70); a type that is not an event name of Relay's form is acknowledged and not recorded.

  `process/1` (the `Relay.Access.EventConsumer` job) applies a receipt by its type:

  * `tenant.created` creates the mapped tenant with its keys (TN-1). Access carries the tenant's `placement` and no time zone or locale (E-95): the region is the one its placement maps to, which is always the installation's own region (INV-41), and the default time zone and locale (TN-2, X-35) are that region's installation defaults from the active `region_defaults` data set; without an active version the job retries. An Access tenant that Access marks with a `platform_product` (a Suiss product such as `access` itself) becomes that product's platform tenant (C-18, E-9, TN-9): an ordinary, isolated tenant with no data privilege; an unknown product is refused.
  * `organization.created` and `organization.updated` are recorded and acknowledged but not applied, `processed` with reason `not_applied`: Access holds no organization name or state yet, so no sub-tenant is created from them (E-95).
  * `api_client.created` registers the client in its tenant's `live` scope as pending, with no environment and no scopes, until a tenant administrator assigns them (E-99, `Relay.Access.Assignment`); a client Relay already knows is left as it is. `api_client.updated` carries nothing Relay keeps and is `processed` with reason `not_applied`. `api_client.suspended`, `api_client.reactivated` and `api_client.revoked` change the API client trace's status and announce the new generation to every node (API-44, TN-24); `api_client.disabled`, which Access emits when it retires a client, suspends it (E-97). A status event of a client that is still pending waits as `deferred` with reason `unknown_client` and is queued again once the client is assigned.
  * `user.suspended`, `user.reactivated` and `user.deleted` go to the configured user event handlers (`config :relay, Relay.Access, user_handlers: [module]`, `Relay.Access.UserHandler`); without one the receipt waits as `deferred` with reason `no_handler`.
  * `consent.updated` goes, in each environment of the mapped tenant, to the configured consent handler (`config :relay, Relay.Access, consent_handler: module`, `Relay.Access.ConsentHandler`) with its status and source in lowercase, the evidence it sealed for that environment when the event was received (the receipt keeps only that ciphertext and never the evidence in clear) and its brand: the sub-tenant mapped from the event's organization, or the tenant itself without one (E-80). A consent that cannot be read is `rejected`; without a handler, or while its organization is not mapped yet, it waits as `deferred`.

  A receipt whose tenant, sub-tenant or client does not exist yet is `deferred` and queued again when a later event of the same Access tenant is applied; anything else that cannot apply is `rejected` with a reason.
  """

  alias Relay.Access.Clients
  alias Relay.Access.ClientStore
  alias Relay.Access.EventConsumer
  alias Relay.Access.EventStore
  alias Relay.Access.Link
  alias Relay.Access.SecurityEvent
  alias Relay.Scope

  @mapping %{
    "tenant.created" => ~w(access_tenant_id placement platform_product),
    "organization.created" => ~w(access_tenant_id access_organization_id),
    "organization.updated" => ~w(access_tenant_id access_organization_id),
    "api_client.created" => ~w(access_tenant_id access_client_id),
    "api_client.updated" => ~w(access_tenant_id access_client_id),
    "api_client.suspended" => ~w(access_tenant_id access_client_id),
    "api_client.disabled" => ~w(access_tenant_id access_client_id),
    "api_client.reactivated" => ~w(access_tenant_id access_client_id),
    "api_client.revoked" => ~w(access_tenant_id access_client_id),
    "user.suspended" => ~w(subject),
    "user.reactivated" => ~w(subject),
    "user.deleted" => ~w(subject),
    "consent.updated" =>
      ~w(sub access_tenant_id access_organization_id channel status consent_kind recipient_type
         source occurred_at text_version_digest evidence iys_transaction_id sequence)
  }
  @statuses %{
    "api_client.suspended" => "suspended",
    "api_client.disabled" => "suspended",
    "api_client.reactivated" => "active",
    "api_client.revoked" => "revoked"
  }
  @users %{
    "user.suspended" => :suspended,
    "user.reactivated" => :reactivated,
    "user.deleted" => :deleted
  }
  @channels ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app webhook)
  @consent_statuses ~w(none pending active revoked expired)
  @consent_kinds ~w(explicit_opt_in soft_opt_in legitimate_interest none)
  @recipient_types ~w(individual merchant)
  @consent_source ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @requeue_after ~w(tenant.created api_client.created)
  @region_defaults "region_defaults"
  @batch 100
  @event_name ~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/

  @type outcome :: :processed | {:processed | :deferred | :rejected, String.t()}

  # E-94
  # E-70
  # E-78
  @doc "Receives a Security Event Token Access pushed; a refusal carries its RFC 8935 error code."
  @spec accept(binary()) :: :ok | {:error, SecurityEvent.refusal()} | {:error, Relay.Error.t()}
  def accept(token) when is_binary(token) do
    with {:ok, event} <- verified(token) do
      record(token, event)
    end
  end

  defp verified(token) do
    with {:error, :unknown_key} <- verify(token) do
      _ = Link.refresh_keys()

      case verify(token) do
        {:error, :unknown_key} -> SecurityEvent.refuse("invalid_key", "the SET key is not known")
        result -> result
      end
    end
  end

  # INV-41
  # TN-57
  # E-90
  defp verify(token) do
    case {Link.current(), Relay.Access.client_id()} do
      {%{state: state, keys: [_ | _] = keys, issuer: issuer}, audience}
      when state in [:ok, :stale] and is_binary(audience) ->
        now = DateTime.to_unix(Relay.Clock.utc_now())
        SecurityEvent.verify(token, keys, %{issuer: issuer, audience: audience, now: now})

      _other ->
        {:error, Relay.Error.new(:service_unavailable, "no Access link")}
    end
  end

  defp record(token, %{jti: jti, type: type, data: data}) do
    if Regex.match?(@event_name, type) and byte_size(type) <= 128 do
      with {:ok, payload} <- sealed(type, minimal(type, data)) do
        store(token, jti, type, payload)
      end
    else
      :ok
    end
  end

  defp store(token, jti, type, payload) do
    attrs = %{
      id: Relay.Id.generate(),
      webhook_id: jti,
      event_type: type,
      access_tenant_id: text(payload["access_tenant_id"], 128),
      payload: payload,
      body_digest: :crypto.hash(:sha256, token),
      traceparent: nil
    }

    case EventStore.record(attrs, &job/1) do
      {:ok, _recorded_or_duplicate} -> :ok
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "not recorded")}
    end
  end

  # E-80
  # PC-59 (1)
  defp sealed("consent.updated", %{"evidence" => evidence} = payload) do
    clear = Map.delete(payload, "evidence")

    with handler when handler != nil <- Keyword.get(Relay.Access.config(), :consent_handler),
         sub when is_binary(sub) <- payload["sub"],
         {:ok, %{} = evidence} <- evidence(evidence),
         %{id: tenant_id} <- ClientStore.tenant(to_string(payload["access_tenant_id"])),
         {:ok, by_environment} <- seal_each(handler, tenant_id, sub, evidence) do
      {:ok, put_sealed(clear, by_environment)}
    else
      {:error, _reason} -> {:error, unsealed()}
      _nothing_to_seal -> {:ok, clear}
    end
  end

  defp sealed(_type, payload), do: {:ok, payload}

  defp seal_each(handler, tenant_id, sub, evidence) do
    Enum.reduce_while(Relay.Environment.all(), {:ok, %{}}, fn environment, {:ok, acc} ->
      case handler.seal_evidence(Scope.new!(tenant_id, environment), sub, evidence) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, %{} = sealed} -> {:cont, {:ok, Map.put(acc, Atom.to_string(environment), sealed)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp put_sealed(payload, sealed) when sealed == %{}, do: payload
  defp put_sealed(payload, sealed), do: Map.put(payload, "evidence_sealed", sealed)

  defp unsealed, do: Relay.Error.new(:service_unavailable, "the consent evidence was not sealed")

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

      {state, reason} when state in [:processed, :deferred, :rejected] ->
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

  defp handle("organization." <> _type, _payload, _receipt), do: {:processed, "not_applied"}

  defp handle("api_client.created", payload, receipt),
    do: with_tenant(payload, &client_created(payload, receipt, &1))

  defp handle("api_client.updated", _payload, _receipt), do: {:processed, "not_applied"}

  defp handle("api_client." <> _ = type, payload, receipt) when is_map_key(@statuses, type),
    do: with_client(payload, &client_status(type, payload, receipt, &1))

  defp handle("user." <> _ = type, payload, receipt) when is_map_key(@users, type),
    do: user(Map.fetch!(@users, type), payload, receipt)

  defp handle("consent.updated", payload, receipt),
    do: with_tenant(payload, &consent(payload, receipt, &1))

  defp handle(_type, _payload, _receipt), do: {:rejected, "unsupported_type"}

  # TN-1
  # TN-2
  # X-35
  # INV-41
  # E-95
  defp tenant_created(payload, receipt) do
    with tenant when is_binary(tenant) <- text(payload["access_tenant_id"], 128),
         {:ok, region} <- placement_region(payload["placement"]),
         {:ok, timezone, locale} <- region_defaults(region) do
      attrs = %{
        id: Relay.Id.generate(),
        access_tenant_id: tenant,
        region: region,
        sector: "general",
        default_timezone: timezone,
        default_locale: locale,
        record_digest: digest(receipt, "tenant")
      }

      provision(attrs, payload["platform_product"], receipt)
    else
      nil -> {:rejected, "tenant_missing"}
      {:rejected, reason} -> {:rejected, reason}
      {:error, error} -> {:error, error}
    end
  end

  # E-95
  # INV-41
  defp placement_region(_placement), do: Relay.Region.cast(Relay.Datasets.installation_region())

  # E-95
  # OP-65 (3)
  defp region_defaults(region) do
    case Relay.Datasets.active(Relay.Datasets.installation_scope(), @region_defaults) do
      {:ok, %{content: %{"regions" => regions}}} -> defaults_of(regions, region)
      {:ok, nil} -> {:error, Relay.Error.new(:service_unavailable, "no region defaults")}
      {:error, error} -> {:error, error}
    end
  end

  defp defaults_of(regions, region) do
    case Enum.find(regions, &(&1["region"] == Relay.Region.dump(region))) do
      %{"time_zone" => timezone, "locale" => locale} -> {:ok, timezone, locale}
      nil -> {:rejected, "defaults_missing"}
    end
  end

  # C-18
  # E-9
  # TN-9
  defp provision(attrs, nil, receipt),
    do: provisioned(Relay.Tenancy.Provisioning.create_tenant(attrs, actor(receipt)))

  defp provision(attrs, product, receipt) do
    case Relay.Access.create_platform_tenant(Map.put(attrs, :product, product), actor(receipt)) do
      {:error, %Relay.Error{code: :invalid_argument}} -> {:rejected, "invalid_product"}
      result -> provisioned(result)
    end
  end

  defp provisioned({result, _id}) when result in [:created, :exists], do: :processed
  defp provisioned({:region_mismatch, _id}), do: {:rejected, "region_mismatch"}
  defp provisioned({:conflict, _id}), do: {:rejected, "conflict"}

  defp provisioned({:error, %Relay.Error{code: code}})
       when code in [:invalid_time_zone, :invalid_locale],
       do: {:rejected, "invalid_defaults"}

  defp provisioned({:error, error}), do: {:error, error}

  defp with_tenant(payload, fun) do
    case ClientStore.tenant(to_string(payload["access_tenant_id"])) do
      %{id: id} -> fun.(id)
      nil -> {:deferred, "unknown_tenant"}
    end
  end

  defp subtenant_in(scope, organization_id),
    do: ClientStore.in_scope(scope, fn _status -> ClientStore.subtenant(organization_id) end)

  # API-44
  # TN-24
  # E-99
  defp client_created(payload, receipt, tenant_id) do
    with client when is_binary(client) <- text(payload["access_client_id"], 256),
         [] <- ClientStore.resolve(to_string(payload["access_tenant_id"]), client) do
      register(Scope.new!(tenant_id, :live), client, receipt)
    else
      nil -> {:rejected, "client_missing"}
      [_known | _more] -> :processed
    end
  end

  defp register(scope, client, receipt) do
    id = Relay.Id.generate()
    digest = digest(receipt, "api_client")
    actor = actor(receipt)
    work = fn _status -> ClientStore.register(id, client, receipt.webhook_id, digest, actor) end

    case ClientStore.in_scope(scope, work) do
      {:ok, {result, _id}} when result in [:created, :exists] -> :processed
      {:error, error} -> {:error, error}
    end
  end

  defp with_client(payload, fun) do
    access_tenant_id = to_string(payload["access_tenant_id"])

    case ClientStore.resolve(access_tenant_id, to_string(payload["access_client_id"])) do
      [%{status: "pending"}] -> {:deferred, "unknown_client"}
      [resolved] -> fun.(resolved)
      _none -> {:deferred, "unknown_client"}
    end
  end

  # API-44
  # TN-24 (5)
  # TN-36
  # E-97
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

  # E-80
  # PC-59 (1)
  defp consent(payload, receipt, tenant_id) do
    case {Keyword.get(Relay.Access.config(), :consent_handler), consent_attrs(payload)} do
      {nil, _attrs} ->
        {:deferred, "no_handler"}

      {_handler, :error} ->
        {:rejected, "invalid_consent"}

      {handler, {:ok, attrs}} ->
        attrs =
          Map.merge(attrs, %{
            source_event_ref: receipt.webhook_id,
            evidence_sealed: sealed_map(payload["evidence_sealed"])
          })

        organization = payload["access_organization_id"]
        scopes = Enum.map(Relay.Environment.all(), &Scope.new!(tenant_id, &1))
        Enum.reduce_while(scopes, :processed, &consent_step(handler, &1, organization, attrs, &2))
    end
  end

  defp consent_step(handler, scope, organization, attrs, :processed) do
    case consent_in(handler, scope, organization, attrs) do
      :ok -> {:cont, :processed}
      other -> {:halt, other}
    end
  end

  defp consent_in(handler, scope, organization, attrs) do
    with {:ok, brand} <- brand(scope, organization) do
      sealed = Map.get(attrs.evidence_sealed, Atom.to_string(scope.environment))

      consent =
        attrs
        |> Map.delete(:evidence_sealed)
        |> Map.merge(%{brand_subtenant_id: brand, sealed_evidence: sealed})

      case handler.handle_consent(scope, consent) do
        :ok -> :ok
        {:rejected, reason} when is_binary(reason) -> {:rejected, reason}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp brand(_scope, nil), do: {:ok, nil}

  defp brand(scope, organization) do
    case subtenant_in(scope, to_string(organization)) do
      {:ok, %{id: id}} -> {:ok, id}
      {:ok, nil} -> {:deferred, "subtenant_not_found"}
      {:error, error} -> {:error, error}
    end
  end

  defp consent_attrs(payload) do
    with sub when is_binary(sub) and sub != "" <- text(payload["sub"], 256),
         channel when channel in @channels <- payload["channel"],
         status when status in @consent_statuses <- lower(payload["status"]),
         source when is_binary(source) <- consent_source(payload["source"]),
         sequence when is_integer(sequence) and sequence >= 0 <- payload["sequence"],
         {:ok, occurred_at} <- timestamp(payload["occurred_at"]),
         {:ok, kind} <- optional(payload["consent_kind"], @consent_kinds),
         {:ok, recipient_type} <- optional(payload["recipient_type"], @recipient_types),
         {:ok, text_digest} <- text_digest(payload["text_version_digest"]) do
      {:ok,
       %{
         sub: sub,
         channel: channel,
         status: status,
         consent_kind: kind,
         recipient_type: recipient_type,
         source: source,
         sequence: sequence,
         occurred_at: occurred_at,
         text_version_digest: text_digest,
         iys_transaction_ref: text(payload["iys_transaction_id"], 128)
       }}
    else
      _invalid -> :error
    end
  end

  defp lower(value) when is_binary(value), do: String.downcase(value)
  defp lower(_value), do: nil

  defp consent_source(value) when is_binary(value) do
    source = value |> String.trim() |> String.downcase()
    if Regex.match?(@consent_source, source), do: source
  end

  defp consent_source(_value), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp optional(nil, _allowed), do: {:ok, nil}
  defp optional(value, allowed), do: if(value in allowed, do: {:ok, value}, else: :error)

  defp text_digest(nil), do: {:ok, nil}

  defp text_digest(hex) when is_binary(hex) and byte_size(hex) == 64,
    do: Base.decode16(hex, case: :lower)

  defp text_digest(_hex), do: :error

  defp sealed_map(%{} = sealed), do: sealed
  defp sealed_map(_sealed), do: %{}

  defp evidence(nil), do: {:ok, nil}

  defp evidence(%{} = evidence) do
    taken = Map.take(evidence, ["ip", "device"])

    if Enum.all?(taken, fn {_key, value} -> is_binary(value) end),
      do: {:ok, taken},
      else: :error
  end

  defp evidence(_evidence), do: :error

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
