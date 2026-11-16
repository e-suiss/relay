defmodule Relay.Webhooks do
  @moduledoc """
  The outbound delivery engine, endpoints and the webhook portal. Other contexts use only the functions of this module.

  One engine serves two uses (WH-1): Relay's own events delivered to the tenant, and the `webhook` channel that delivers a tenant's events to its consumers. Its concepts are the event type, the consumer, the endpoint, the message (one event for one endpoint) and the attempt (WH-2). Delivery is at least once: an event can arrive more than once and in any order, the consumer deduplicates by `webhook-id`, and the definite state is always read from the API (WH-3).

  This module holds the management side: consumers, tenant event types with versioned schemas (WH-14), endpoints with their versions, subscription and limits (WH-12, WH-16), per-endpoint signing keys with overlapping rotation (WH-5, WH-6), the registration rules of an address (WH-40) and the tenant's operations contacts (WH-56). A function that takes a scope opens its own scoped transaction; one that takes none runs inside the caller's. A function that reaches the key store (`new_key/2`, `sign/5`, `seal_contacts/2`, `contacts/1`) never runs inside a transaction.

  This module is also the behaviour of the engine's runtime, the port through which the engine uses the rest of a running node (T-56): the job queue with its tenant fairness, the cluster-wide concurrency and rate limits, the source of an event's snapshot fields, destination credentials and the operations e-mail. It is configured as `runtime: Module`; `Relay.Webhooks.Live` is the implementation of a running node. `c:enqueue/1` and `c:cancel/1` run inside the caller's scoped transaction, so a message and its job commit together; the other callbacks never run inside a transaction.

  The signer and the sealer are ports: `config :relay, Relay.Webhooks, signer: Module, sealer: Module`, by default `Relay.Webhooks.Signer.KeyStore` and `Relay.Webhooks.Live`. The same configuration holds the installation's egress policy (`Relay.Webhooks.Egress.Policy`): `deployment: :saas | :self_hosted` (`:saas` when absent), `extra_ports: [port]` for HTTPS ports besides 443 (WH-40 (2)), `allow_list: [entry]` for the internal targets of a self-hosted installation (WH-44), and `resolver: Module` for the DNS port.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Actor
  alias Relay.Scope
  alias Relay.Webhooks.Egress
  alias Relay.Webhooks.Egress.Policy
  alias Relay.Webhooks.Engine
  alias Relay.Webhooks.EngineStore
  alias Relay.Webhooks.EventSchema
  alias Relay.Webhooks.Fanout
  alias Relay.Webhooks.Health
  alias Relay.Webhooks.Profile
  alias Relay.Webhooks.Settings
  alias Relay.Webhooks.Signer
  alias Relay.Webhooks.Store
  alias Relay.Webhooks.Sweeper

  @signer Relay.Webhooks.Signer.KeyStore
  @sealer Relay.Webhooks.Live
  @contact_field {"operations_contacts", "address_ct"}
  @limits %{
    per_tenant: Relay.Limits.fetch!(["webhook", "endpoints_per_tenant"]),
    per_consumer: Relay.Limits.fetch!(["webhook", "endpoints_per_consumer"])
  }
  @ports Relay.Limits.fetch!(["webhook", "allowed_ports"])
  @dns_timeout_ms 1000 * Relay.Limits.seconds!(["webhook", "connect_timeout"])
  @contacts_max Relay.Limits.fetch!(["webhook", "operations_contacts_max"])
  @overlap %{
    default: Relay.Limits.seconds!(["webhook", "key_overlap", "default"]),
    max: Relay.Limits.seconds!(["webhook", "key_overlap", "max"])
  }
  @tolerance_s Relay.Limits.seconds!(["webhook", "signature_tolerance"])

  @type result(value) :: {:ok, value} | {:error, term()}

  @typedoc "A job of the engine: `:worker`, `:args` (identifiers only), the `:message_id` or `:endpoint_id` it works for and, when it is not due at once, `:scheduled_at`."
  @type job :: %{
          required(:worker) => module(),
          required(:args) => map(),
          required(:ref_id) => Relay.Id.t(),
          optional(:scheduled_at) => DateTime.t() | nil
        }

  @typedoc "An operations e-mail: its sender address, its subject and its plain text."
  @type mail :: %{from: String.t(), subject: String.t(), text: String.t()}

  @doc "Queues a job inside the caller's scoped transaction."
  @callback enqueue(job()) :: :ok | {:error, term()}

  @doc "Cancels the waiting jobs of a message inside the caller's scoped transaction."
  @callback cancel(Relay.Id.t()) :: :ok

  @doc "Runs `fun` while holding one of the `limit` concurrency slots of an endpoint for `holder`, or answers `{:full, wait_ms}` without running it."
  @callback with_slot(Scope.t(), Relay.Id.t(), pos_integer(), String.t(), (-> term())) ::
              {:ok, term()} | {:full, non_neg_integer()}

  @doc "Spends one delivery of an endpoint's rate of `per_second`, or answers the wait in milliseconds."
  @callback rate(Scope.t(), Relay.Id.t(), pos_integer()) :: :allow | {:deny, pos_integer()}

  @doc "The data of the outbox event behind an event, with the identifiers in their external form, from which snapshot fields are taken; `nil` when it is no longer kept."
  @callback event_source(Scope.t(), Relay.Id.t(), DateTime.t()) :: map() | nil

  @doc "Resolves the credential of a destination from its secret reference for this call only (WH-19), or `nil` when it cannot be resolved."
  @callback credential(Scope.t(), Relay.Id.t()) :: Relay.Redacted.t() | nil

  @doc "Sends an operations e-mail to the tenant's contacts through the platform tenant's e-mail channel."
  @callback mail(Scope.t(), [Relay.Redacted.t(), ...], mail()) :: :ok | {:error, term()}
  @type id :: Relay.Id.t()
  @type cursor :: map() | nil

  # WH-49
  @doc "Records an inbound provider receipt in its own scoped transaction; commit it before answering the provider."
  @spec record_receipt(Relay.Scope.t(), map()) ::
          {:ok, {:recorded | :duplicate, Relay.Id.t() | nil}} | {:error, term()}
  def record_receipt(scope, receipt),
    do: Store.in_scope(scope, fn _status -> Store.receipt_record(receipt) end)

  # WH-49
  @doc "Records an inbound provider receipt inside the caller's scoped transaction, so the job that processes it is queued in the same transaction."
  @spec receipt_record(map()) :: {:recorded | :duplicate, Relay.Id.t() | nil}
  defdelegate receipt_record(receipt), to: Store

  # WH-49
  @doc "Reads a receipt inside the caller's scoped transaction: its provider, state and sealed body, or `nil`."
  @spec receipt(Relay.Id.t()) :: map() | nil
  defdelegate receipt(receipt_id), to: Store

  # WH-49
  @doc "Marks a receipt inside the caller's scoped transaction."
  @spec receipt_mark(Relay.Id.t(), :processed | :rejected, String.t() | nil) ::
          :marked | :already_final | :not_found
  defdelegate receipt_mark(receipt_id, state, reason), to: Store

  @doc "Marks a receipt that produces no ledger event."
  @spec mark_receipt(Relay.Scope.t(), Relay.Id.t(), :processed | :rejected, String.t() | nil) ::
          {:ok, atom()} | {:error, term()}
  def mark_receipt(scope, receipt_id, state, reason),
    do: Store.in_scope(scope, fn _status -> Store.receipt_mark(receipt_id, state, reason) end)

  # WH-4
  # WH-7 (2)
  # WH-49 (2)
  # WH-50
  # WH-51
  @doc """
  Verifies an inbound message of the Suiss webhook profile with `Relay.Webhooks.Profile.verify/5`, the verifier of outbound deliveries: a provider that follows Standard Webhooks, a completion notification of a long-running job from another Suiss product, or any other sender of the profile. `headers` are the request headers as they arrived, `raw_body` the bytes that arrived and never a body that was parsed and serialised again, and `keys` the text forms of every key that may have signed it (`whpk_…` for Ed25519, `whsec_…` for HMAC-SHA256), so that a message signed during a rotation overlap verifies under either key. A key that is not of a text form is left out.

  The message is accepted when any signature verifies against any key; signatures are compared in constant time, and a `webhook-timestamp` further from `now` than the `signature_tolerance` limit, in either direction, is refused. The unsigned headers carry no security meaning and are not read (WH-9). The caller records the returned `id` durably and processes an identifier only once: delivery is at least once.
  """
  @spec verify_message(
          Profile.headers(),
          binary(),
          [String.t() | Relay.Redacted.t()],
          DateTime.t()
        ) :: {:ok, Profile.verified()} | {:error, Profile.rejection()}
  def verify_message(headers, raw_body, keys, %DateTime{} = now)
      when is_binary(raw_body) and is_list(keys) do
    parsed = for key <- keys, {:ok, parsed} <- [Profile.parse_key(key_text(key))], do: parsed
    Profile.verify(headers, raw_body, parsed, now, @tolerance_s)
  end

  defp key_text(key), do: key |> Relay.Redacted.wrap() |> Relay.Redacted.expose()

  # WH-16
  # WH-52
  @doc "The endpoint limits: `:per_tenant` for a tenant's own `relay_events` endpoints and `:per_consumer` for the endpoints of one consumer."
  @spec endpoint_limits() :: %{per_tenant: pos_integer(), per_consumer: pos_integer()}
  def endpoint_limits, do: @limits

  # WH-6
  @doc "The rotation overlap in seconds: the `:default` and the `:max` a request may ask for."
  @spec key_overlap() :: %{default: non_neg_integer(), max: pos_integer()}
  def key_overlap, do: @overlap

  # WH-56
  @doc "How many operations contact addresses a tenant environment holds at most."
  @spec contacts_max() :: pos_integer()
  def contacts_max, do: @contacts_max

  # WH-40
  @doc "The HTTPS ports an address may use: 443 and the ports the installation adds."
  @spec allowed_ports() :: [pos_integer()]
  def allowed_ports, do: Enum.uniq(@ports ++ policy().ports)

  # WH-40
  # WH-54
  @doc "Checks an HTTPS address against the registration rules of the egress boundary (`Relay.Webhooks.Egress.validate_url/2`) with the installation's policy; `explain_address/1` words a refusal."
  @spec check_address(String.t()) :: :ok | {:error, Egress.url_error()}
  def check_address(url) do
    case Egress.validate_url(policy(), url) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # WH-40 (4)
  @doc "The early DNS check of a registration, outside any transaction: the addresses of the URL's host that the boundary would refuse, as text. It is feedback for the person registering, never the security decision, which is made when Relay connects (WH-41); a name that does not resolve yet reports nothing."
  @spec blocked_addresses(String.t()) :: {:ok, [String.t()]} | {:error, Egress.url_error()}
  def blocked_addresses(url) do
    options = [dns_timeout_ms: @dns_timeout_ms, resolver: resolver()]

    with {:ok, findings} <- Egress.dns_findings(policy(), url, options) do
      {:ok, for({:blocked_address, address, _range} <- findings, do: address)}
    end
  end

  # WH-40
  @doc "The sentence that explains a refusal of `check_address/1`."
  @spec explain_address(Egress.url_error()) :: String.t()
  def explain_address(:invalid_url), do: "the address is not a URL"
  def explain_address(:scheme_not_https), do: "the address must be https"
  def explain_address(:userinfo_not_allowed), do: "the address must not carry user information"
  def explain_address(:invalid_host), do: "the address names no public host"
  def explain_address(:port_not_allowed), do: "the port is not allowed by the installation"
  def explain_address(:metadata_host), do: "the host is not allowed"
  def explain_address(:blocked_address), do: "the address is in a blocked range"

  # WH-2
  @doc "Creates a consumer inside the caller's scoped transaction; `attrs` carries `:key` and optionally `:name`, `:source` and `:subtenant_id`. Returns the result, the consumer's identifier and its version."
  @spec consumer_create(map(), binary(), Actor.t()) :: {atom(), id() | nil, pos_integer() | nil}
  defdelegate consumer_create(attrs, digest, actor), to: Store

  # WH-2
  @doc "Changes the `name` or `source` of a consumer inside the caller's scoped transaction; `changes` holds only the fields to change."
  @spec consumer_update(id(), pos_integer() | nil, map(), binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  defdelegate consumer_update(id, expected_version, changes, digest, actor), to: Store

  # WH-2
  @doc "Archives a consumer inside the caller's scoped transaction; a consumer with an endpoint that is not archived is `:in_use`."
  @spec consumer_archive(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate consumer_archive(id, digest, actor), to: Store

  # WH-2
  @doc "Reads a consumer inside the caller's scoped transaction, or `nil`."
  @spec consumer(id()) :: map() | nil
  defdelegate consumer(id), to: Store

  # WH-2
  @doc "Reads a consumer, or `nil`."
  @spec get_consumer(Scope.t(), id()) :: result(map() | nil)
  def get_consumer(%Scope{} = scope, id), do: read(scope, fn -> Store.consumer(id) end)

  # WH-2
  # API-56
  @doc "Lists consumers from a decoded cursor, optionally of one state; at most `limit + 1` come back."
  @spec list_consumers(Scope.t(), String.t() | nil, cursor(), pos_integer()) :: result([map()])
  def list_consumers(%Scope{} = scope, state, cursor, limit),
    do: read(scope, fn -> Store.consumers(state, cursor, limit) end)

  # WH-14
  @doc "Creates a tenant event type with the first version of its schema inside the caller's scoped transaction; `attrs` carries `:name`, `:schema`, `:schema_digest`, `:identifiers` and optionally `:description` and `:example`."
  @spec event_type_create(map(), binary(), Actor.t()) :: {atom(), id() | nil}
  defdelegate event_type_create(attrs, digest, actor), to: Store

  # WH-14
  @doc "Opens the next schema version of a tenant event type inside the caller's scoped transaction; the current schema again is `:unchanged`."
  @spec event_type_version_add(id(), map(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate event_type_version_add(id, attrs, digest, actor), to: Store

  # WH-14
  @doc "Archives a tenant event type inside the caller's scoped transaction."
  @spec event_type_archive(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate event_type_archive(id, digest, actor), to: Store

  # WH-14
  @doc "Reads a tenant event type with its current schema version inside the caller's scoped transaction, or `nil`."
  @spec event_type(id()) :: map() | nil
  defdelegate event_type(id), to: Store

  # WH-14
  @doc "Reads one schema version of a tenant event type inside the caller's scoped transaction, or `nil`."
  @spec event_type_version(id(), pos_integer()) :: map() | nil
  defdelegate event_type_version(id, version), to: Store

  # WH-14
  @doc "Reads a tenant event type with its current schema version, or `nil`."
  @spec get_event_type(Scope.t(), id()) :: result(map() | nil)
  def get_event_type(%Scope{} = scope, id), do: read(scope, fn -> Store.event_type(id) end)

  # WH-14
  # API-56
  @doc "Lists tenant event types from a decoded cursor, optionally of one state."
  @spec list_event_types(Scope.t(), String.t() | nil, cursor(), pos_integer()) :: result([map()])
  def list_event_types(%Scope{} = scope, state, cursor, limit),
    do: read(scope, fn -> Store.event_types(state, cursor, limit) end)

  # WH-14
  @doc "Reads one schema version of a tenant event type, or `nil`."
  @spec get_event_type_version(Scope.t(), id(), pos_integer()) :: result(map() | nil)
  def get_event_type_version(%Scope{} = scope, id, version),
    do: read(scope, fn -> Store.event_type_version(id, version) end)

  # WH-14
  # API-56
  @doc "Lists the schema versions of a tenant event type, newest first, or `:not_found` for an unknown type."
  @spec list_event_type_versions(Scope.t(), id(), cursor(), pos_integer()) ::
          result(:not_found | [map()])
  def list_event_type_versions(%Scope{} = scope, id, cursor, limit) do
    read(scope, fn ->
      if Store.event_type(id), do: Store.event_type_versions(id, cursor, limit), else: :not_found
    end)
  end

  # WH-13
  # WH-14
  @doc "Checks the schema of a tenant event type with its identifiers and example, and returns the schema's digest; see `Relay.Webhooks.EventSchema.check/3`."
  @spec check_event_schema(map(), [String.t()], map() | nil) ::
          {:ok, <<_::256>>} | {:error, EventSchema.reason()}
  defdelegate check_event_schema(schema, identifiers, example), to: EventSchema, as: :check

  # WH-5
  # TN-32
  @doc "Makes a signing key of `scheme` (`v1a` or `v1`, as text) for a new endpoint or a rotation, outside any transaction; see `Relay.Webhooks.Signer`. The `:secret` of a `v1` key is shown once and kept nowhere else."
  @spec new_key(Scope.t(), String.t()) :: {:ok, Signer.generated()} | {:error, Relay.Error.t()}
  def new_key(%Scope{} = scope, scheme) when scheme in ["v1a", "v1"] do
    {:ok, scheme} = Signer.scheme(scheme)
    signer().generate(scope, scheme)
  end

  # WH-2
  # WH-16
  # WH-45
  @doc """
  Creates an endpoint in the environment of the caller's scoped transaction, with its first version and, for an `https` endpoint, the signing key `key` made by `new_key/2`. `attrs` carries `:use`, `:kind`, `:destination`, `:event_types`, `:snapshot`, `:settings` and `:payload_version`, and optionally `:consumer` (the consumer's key), `:url`, `:credential_ref_id`, `:signature_scheme` and `:description`. The environment is the transaction's and is never an attribute. Returns the result and the endpoint's identifier.
  """
  @spec endpoint_create(map(), Signer.generated() | nil, binary(), Actor.t()) ::
          {atom(), id() | nil}
  def endpoint_create(attrs, key, digest, %Actor{} = actor),
    do: Store.endpoint_create(attrs, key, @limits, digest, actor)

  # WH-12
  # WH-48
  @doc "Changes an endpoint inside the caller's scoped transaction; `changes` holds only the fields to change, by their column name. A changed `\"snapshot\"` opens a new endpoint version."
  @spec endpoint_update(id(), pos_integer() | nil, map(), binary(), Actor.t()) ::
          {atom(), pos_integer() | nil}
  defdelegate endpoint_update(id, expected_version, changes, digest, actor), to: Store

  # WH-48
  @doc "Archives an endpoint and retires its signing keys inside the caller's scoped transaction."
  @spec endpoint_archive(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  defdelegate endpoint_archive(id, digest, actor), to: Store

  # WH-6
  # WH-48
  @doc "Makes `key`, made by `new_key/2`, the active signing key of an endpoint inside the caller's scoped transaction; the key it replaces keeps signing for `overlap_s` seconds, and with `0` stops at once. Returns the result, the previous key's identifier and when it stops."
  @spec endpoint_key_rotate(id(), Signer.generated(), non_neg_integer(), binary(), Actor.t()) ::
          {atom(), id() | nil, DateTime.t() | nil}
  defdelegate endpoint_key_rotate(id, key, overlap_s, digest, actor), to: Store

  # WH-2
  # WH-5
  @doc "Reads an endpoint inside the caller's scoped transaction with the snapshot of its current version and, under `\"keys\"`, the keys that sign now, the active one first; or `nil`."
  @spec endpoint(id()) :: map() | nil
  def endpoint(id) do
    case Store.endpoint(id) do
      nil -> nil
      row -> [row] |> with_keys() |> hd()
    end
  end

  # WH-2
  @doc "Reads an endpoint as `endpoint/1` does, or `nil`."
  @spec get_endpoint(Scope.t(), id()) :: result(map() | nil)
  def get_endpoint(%Scope{} = scope, id), do: read(scope, fn -> endpoint(id) end)

  # WH-2
  # API-56
  @doc "Lists endpoints as `endpoint/1` reads them, newest first, filtered by `:use`, `:state` and `:consumer_id` when given."
  @spec list_endpoints(Scope.t(), map(), cursor(), pos_integer()) :: result([map()])
  def list_endpoints(%Scope{} = scope, filters, cursor, limit),
    do: read(scope, fn -> filters |> Store.endpoints(cursor, limit) |> with_keys() end)

  # WH-12
  @doc "Reads one version of an endpoint, or `nil`."
  @spec get_endpoint_version(Scope.t(), id(), pos_integer()) :: result(map() | nil)
  def get_endpoint_version(%Scope{} = scope, id, version),
    do: read(scope, fn -> Store.endpoint_version(id, version) end)

  # WH-12
  # API-56
  @doc "Lists the versions of an endpoint, newest first, or `:not_found` for an unknown endpoint."
  @spec list_endpoint_versions(Scope.t(), id(), cursor(), pos_integer()) ::
          result(:not_found | [map()])
  def list_endpoint_versions(%Scope{} = scope, id, cursor, limit) do
    read(scope, fn ->
      if Store.endpoint(id), do: Store.endpoint_versions(id, cursor, limit), else: :not_found
    end)
  end

  # WH-5
  # WH-6
  @doc "The signing keys of an endpoint as the signer takes them: the active key first, then a previous key whose overlap has not ended. Their secrets are sealed."
  @spec signing_keys(Scope.t(), id()) :: result([Signer.key()])
  def signing_keys(%Scope{} = scope, endpoint_id),
    do: read(scope, fn -> Store.signing_keys(endpoint_id, Relay.Clock.utc_now()) end)

  # WH-4
  # WH-6
  @doc "Signs a delivery attempt outside any transaction and returns its profile tokens (`Relay.Webhooks.Profile`), one per key of `keys`, the new key's first. The signed content is exactly `<webhook_id>.<timestamp>.<body>`."
  @spec signature_tokens(
          Scope.t(),
          [Signer.key(), ...],
          String.t(),
          non_neg_integer(),
          binary()
        ) :: {:ok, [Profile.token(), ...]} | {:error, Relay.Error.t()}
  def signature_tokens(%Scope{} = scope, [_ | _] = keys, webhook_id, timestamp, body),
    do: signer().sign(scope, keys, Profile.signed_content(webhook_id, timestamp, body))

  # WH-4
  # WH-6
  @doc "Signs a delivery attempt as `signature_tokens/5` does and returns the `webhook-signature` header."
  @spec sign(Scope.t(), [Signer.key(), ...], String.t(), non_neg_integer(), binary()) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def sign(%Scope{} = scope, [_ | _] = keys, webhook_id, timestamp, body) do
    with {:ok, tokens} <- signature_tokens(scope, keys, webhook_id, timestamp, body),
         do: {:ok, Profile.signature_header(tokens)}
  end

  # WH-5
  @doc "The public form of an Ed25519 public key (`whpk_` and base64), or `nil` for a key without one."
  @spec public_key(binary() | nil) :: String.t() | nil
  def public_key(<<_::256>> = key), do: Profile.public_key_text(key)
  def public_key(nil), do: nil

  # WH-6
  @doc "Retires the previous keys of the scope whose overlap ended; returns how many."
  @spec expire_keys(Scope.t()) :: result(non_neg_integer())
  def expire_keys(%Scope{} = scope), do: read(scope, &Store.keys_expire/0)

  # WH-56
  @doc "Seals operations contact addresses outside any transaction, for `contacts_replace/3`."
  @spec seal_contacts(Scope.t(), [String.t()]) ::
          {:ok, %{cts: [binary()], key_id: id() | nil}} | {:error, Relay.Error.t()}
  def seal_contacts(%Scope{}, []), do: {:ok, %{cts: [], key_id: nil}}

  def seal_contacts(%Scope{} = scope, [_ | _] = addresses) do
    addresses
    |> Enum.reduce_while({:ok, [], nil}, fn address, {:ok, cts, _key_id} ->
      case sealer().seal(scope, @contact_field, Relay.Redacted.wrap(address)) do
        {:ok, %{ct: ct, key_id: key_id}} -> {:cont, {:ok, [ct | cts], key_id}}
        {:error, %Relay.Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> sealed()
  end

  defp sealed({:ok, cts, key_id}), do: {:ok, %{cts: Enum.reverse(cts), key_id: key_id}}
  defp sealed({:error, error}), do: {:error, error}

  # WH-56
  # WH-48
  @doc "Replaces the operations contacts with addresses sealed by `seal_contacts/2`, inside the caller's scoped transaction; the removed addresses are erased."
  @spec contacts_replace(%{cts: [binary()], key_id: id() | nil}, binary(), Actor.t()) ::
          :replaced | :tenant_inactive
  def contacts_replace(%{cts: cts, key_id: key_id}, digest, %Actor{} = actor),
    do: Store.contacts_replace(cts, key_id, @contacts_max, digest, actor)

  # WH-56
  @doc "The operations contact addresses of the scope, oldest first, redacted, with the time of their last replacement. An address that no longer opens is left out. Runs outside any transaction."
  @spec contacts(Scope.t()) ::
          {:ok, %{addresses: [Relay.Redacted.t()], updated_at: DateTime.t() | nil}}
          | {:error, term()}
  def contacts(%Scope{} = scope) do
    with {:ok, rows} <- read(scope, &Store.contacts/0) do
      addresses =
        for row <- rows,
            {:ok, address} <- [open_contact(scope, row)],
            do: address

      {:ok, %{addresses: addresses, updated_at: rows |> Enum.map(& &1["created_at"]) |> latest()}}
    end
  end

  defp open_contact(scope, row),
    do: sealer().open(scope, @contact_field, row["address_key_id"], row["address_ct"])

  defp latest([]), do: nil
  defp latest(times), do: Enum.max(times, DateTime)

  # WH-41
  @doc "The egress policy of the installation, as every delivery uses it; see `Relay.Webhooks.Egress.Policy`."
  @spec egress_policy() :: Policy.t()
  def egress_policy, do: policy()

  @doc "The DNS port of the installation."
  @spec resolver() :: module()
  def resolver, do: Keyword.get(config(), :resolver, Egress.Resolver.Inet)

  # WH-1
  # WH-2
  # WH-11
  # INV-12
  # OP-7
  @doc "Records one of Relay's own events and creates its messages with their jobs, inside the caller's scoped transaction: the transaction of the outbox dispatcher. Dispatching the same event again creates nothing. See `Relay.Webhooks.Fanout.relay_event/1`."
  @spec deliver_event(Fanout.event()) :: [map()]
  defdelegate deliver_event(event), to: Fanout, as: :relay_event

  # WH-32 (4)
  @doc "Makes one delivery attempt of a message outside any transaction; see `Relay.Webhooks.Engine.attempt/3`. The attempt worker calls it; `manual: true` is a resend."
  @spec attempt(Scope.t(), id(), keyword()) :: {:ok, Engine.result()} | {:error, term()}
  defdelegate attempt(scope, message_id, opts \\ []), to: Engine

  # WH-2
  @doc "Reads a message inside the caller's scoped transaction, or `nil`."
  @spec message(id()) :: map() | nil
  defdelegate message(id), to: EngineStore

  # WH-2
  @doc "Reads a message, or `nil`."
  @spec get_message(Scope.t(), id()) :: result(map() | nil)
  def get_message(%Scope{} = scope, id), do: read(scope, fn -> EngineStore.message(id) end)

  # WH-4
  @doc "The `webhook-id` of the event of a message read by `message/1`, inside the caller's scoped transaction: the identifier a consumer deduplicates by, the same for every attempt, resend, recovery and replay (WH-33)."
  @spec webhook_id(map()) :: String.t()
  def webhook_id(%{"event_id" => event_id}),
    do: event_id |> EngineStore.event() |> Engine.webhook_id()

  # WH-31
  # WH-32 (1)
  # WH-32 (2)
  @doc "Queues one attempt of a message at once, inside the caller's scoped transaction: a resend. If it succeeds the message is delivered and its waiting attempts are cancelled; if it fails the message keeps its state and schedule, and the attempt does not count against the schedule. Attempts of one message never run at the same time."
  @spec resend(id()) :: :ok | {:error, term()}
  def resend(message_id), do: Fanout.attempt_job(message_id, nil, true)

  # WH-31
  # WH-32 (3)
  # WH-33 (1)
  @doc "Starts the schedule of messages from the beginning, inside the caller's scoped transaction: the building block of `recover` and of a bulk retry. The event identifier stays. Returns how many were restarted; see `Relay.Webhooks.Fanout.restart/1`."
  @spec restart_messages([id()]) :: non_neg_integer()
  defdelegate restart_messages(message_ids), to: Fanout, as: :restart

  # WH-31
  @doc "Cancels the scheduled attempts of messages inside the caller's scoped transaction; they become `cancelled`. Returns how many; see `Relay.Webhooks.Fanout.cancel/2`."
  @spec cancel_messages([id()], String.t()) :: non_neg_integer()
  defdelegate cancel_messages(message_ids, actor_ref), to: Fanout, as: :cancel

  # WH-31
  # WH-33 (1)
  @doc "Creates the message of an existing event for another endpoint inside the caller's scoped transaction: a replay with the same `webhook-id`. Returns the message's identifier or `nil`; see `Relay.Webhooks.Fanout.replay/2`."
  @spec replay_event(id(), id()) :: id() | nil
  defdelegate replay_event(event_id, endpoint_id), to: Fanout, as: :replay

  # WH-31
  # WH-33 (2)
  @doc "Queues the release of an endpoint's held messages inside the caller's scoped transaction; `hold_reason` is `endpoint_paused`, `endpoint_disabled` or `breaker_open`. The release runs at a controlled rate within the endpoint's limits."
  @spec release_held_job(id(), String.t()) :: :ok | {:error, term()}
  def release_held_job(endpoint_id, hold_reason),
    do: Fanout.release_job(endpoint_id, hold_reason, nil)

  # WH-31
  # WH-33 (2)
  @doc "Releases one batch of an endpoint's held messages in its own transaction; the release worker calls it. See `Relay.Webhooks.Fanout.release/3`."
  @spec release_held(Scope.t(), id(), String.t(), pos_integer()) :: result(non_neg_integer())
  def release_held(%Scope{} = scope, endpoint_id, hold_reason, batch),
    do: read(scope, fn -> Fanout.release(endpoint_id, hold_reason, batch) end)

  # WH-31
  # WH-48
  @doc "Pauses an endpoint inside the caller's scoped transaction: its messages are held, not dropped. Returns the result (`:changed`, `:unchanged`, `:not_found`, `:archived`, `:managed` or `:invalid_state`) and the endpoint's row version."
  @spec endpoint_pause(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def endpoint_pause(id, digest, %Actor{} = actor),
    do: EngineStore.endpoint_set_state(id, "paused", nil, digest, actor, Relay.Clock.utc_now())

  # WH-31
  # WH-48
  @doc "Resumes a paused endpoint inside the caller's scoped transaction and queues the release of its held messages. Returns as `endpoint_pause/3` does."
  @spec endpoint_resume(id(), binary(), Actor.t()) :: {atom(), pos_integer() | nil}
  def endpoint_resume(id, digest, %Actor{} = actor) do
    now = Relay.Clock.utc_now()

    case EngineStore.endpoint_set_state(id, "active", nil, digest, actor, now) do
      {:changed, version} ->
        :ok = Fanout.release_job(id, "endpoint_paused", nil)
        {:changed, version}

      other ->
        other
    end
  end

  # WH-34
  @doc "Appends `webhook_endpoint.recovered` to the outbox inside the caller's scoped transaction, when a disabled endpoint was enabled again."
  @spec endpoint_recovered(id()) :: :ok
  def endpoint_recovered(id) do
    payload = %{"endpoint_id" => Relay.ExternalId.encode("whe", id)}
    :appended = EngineStore.outbox_append("webhook_endpoint.recovered", id, payload)
    :ok
  end

  # WH-45 (3)
  @doc "Creates the test event of an endpoint read by `endpoint/1` and queues its one attempt, inside the caller's scoped transaction; returns the message or `nil`."
  @spec test_event(map()) :: map() | nil
  def test_event(%{"id" => _id} = endpoint) do
    case Fanout.test_event(endpoint) do
      nil -> nil
      message_id -> EngineStore.message(message_id)
    end
  end

  # WH-39
  @doc "The health of an endpoint: the endpoint, its health row, the attempt statistics of the health window, its backlog and when it is disabled automatically if it keeps failing; `nil` for an unknown endpoint."
  @spec endpoint_health(Scope.t(), id()) :: result(map() | nil)
  def endpoint_health(%Scope{} = scope, id) do
    now = Relay.Clock.utc_now()
    window_s = Settings.health_window_s()

    read(scope, fn ->
      with %{} = endpoint <- EngineStore.endpoint(id) do
        health = EngineStore.health(id)

        %{
          endpoint: endpoint,
          health: health,
          window_s: window_s,
          statistics: EngineStore.statistics(id, DateTime.add(now, -window_s, :second)),
          backlog: EngineStore.backlog(id),
          disable_at: Health.disable_at(health, endpoint["auto_disable"], Settings.health())
        }
      end
    end)
  end

  # WH-28
  # WH-32 (4)
  # WH-36
  @doc "Runs the engine's sweep in every scope that has work for it; returns how many scopes were swept. See `Relay.Webhooks.Sweeper`."
  @spec sweep(pos_integer()) :: non_neg_integer()
  defdelegate sweep(limit \\ 100), to: Sweeper, as: :run

  @doc "Runs the engine's sweep in one scope; see `Relay.Webhooks.Sweeper.scope/1`."
  @spec sweep_scope(Scope.t()) :: result(map())
  defdelegate sweep_scope(scope), to: Sweeper, as: :scope

  # WH-6
  # TN-63
  @doc "Destroys the key store objects of the scope's retired `v1a` keys, outside any transaction, so that a retired key can never sign again; returns how many keys were finished. A key whose object could not be destroyed is tried again on the next run."
  @spec destroy_retired_keys(Scope.t()) :: result(non_neg_integer())
  def destroy_retired_keys(%Scope{} = scope) do
    with {:ok, keys} <- read(scope, fn -> EngineStore.retired_keys(100) end) do
      destroyed = for %{"id" => id} <- keys, signer().destroy(id) == :ok, do: id
      read(scope, fn -> EngineStore.keys_destroyed(destroyed, Relay.Clock.utc_now()) end)
    end
  end

  # WH-30
  # WH-52
  @doc "Erases one batch of the answers and event payloads of the scope whose retention ended: the contract's periods, or the shorter ones of the tenant's `webhook.retention` setting. Rows stay. Returns how many of each were erased."
  @spec retire_due(Scope.t(), pos_integer()) ::
          result(%{responses: non_neg_integer(), payloads: non_neg_integer()})
  def retire_due(%Scope{} = scope, limit) do
    defaults = Settings.retention()
    now = Relay.Clock.utc_now()

    read(scope, fn ->
      setting = EngineStore.retention_setting() || %{}
      min = defaults.min_days
      messages = days(setting["messages_days"], defaults.messages_days, min)
      responses = days(setting["response_body_days"], defaults.response_body_days, min)
      EngineStore.retention_sweep(messages, responses, limit, now)
    end)
  end

  defp days(value, default, min) when is_integer(value), do: value |> max(min) |> min(default)
  defp days(_unset, default, _min), do: default

  defp with_keys([]), do: []

  defp with_keys(rows) do
    keys = rows |> Enum.map(& &1["id"]) |> Store.keys(Relay.Clock.utc_now())
    by_endpoint = Enum.group_by(keys, & &1["endpoint_id"])
    Enum.map(rows, &Map.put(&1, "keys", Map.get(by_endpoint, &1["id"], [])))
  end

  defp read(scope, fun), do: Store.in_scope(scope, fn _status -> fun.() end)

  defp policy do
    config = config()

    {:ok, policy} =
      Policy.new(
        deployment: Keyword.get(config, :deployment, :saas),
        extra_ports: Keyword.get(config, :extra_ports, []),
        allow_list: Keyword.get(config, :allow_list, [])
      )

    policy
  end

  defp signer, do: Keyword.get(config(), :signer, @signer)
  defp sealer, do: Keyword.get(config(), :sealer, @sealer)
  defp config, do: Application.get_env(:relay, __MODULE__, [])
end
