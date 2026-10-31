defmodule Relay.Ingest do
  @moduledoc """
  Event intake, idempotency and deduplication. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Ingest.Accept
  alias Relay.Ingest.CloudEvents
  alias Relay.Ingest.EventStore
  alias Relay.Ingest.Idempotency
  alias Relay.Ingest.Pointer
  alias Relay.Ingest.Request
  alias Relay.Ingest.SendMode
  alias Relay.Ingest.Store

  @type actor :: Relay.Actor.t()
  @type reason :: String.t() | nil

  # OP-7
  # INV-2
  @doc "Accepts notifications in one transaction; see `Relay.Ingest.Accept`."
  @spec accept(Relay.Scope.t(), map()) ::
          {:ok, Accept.outcome() | Accept.replay()} | {:error, Relay.Error.t()}
  defdelegate accept(scope, request), to: Accept, as: :run

  # API-11
  @doc "Reads an `Idempotency-Key` header value."
  @spec parse_idempotency_key(term()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  defdelegate parse_idempotency_key(value), to: Idempotency, as: :parse_key

  # API-13
  @doc "Returns the SHA-256 fingerprint of a raw request body."
  @spec idempotency_fingerprint(iodata()) :: <<_::256>>
  defdelegate idempotency_fingerprint(raw_body), to: Idempotency, as: :fingerprint

  # API-14
  @doc "Returns true if a response with this status is stored for replay."
  @spec idempotency_cacheable?(100..599) :: boolean()
  defdelegate idempotency_cacheable?(status), to: Idempotency, as: :cacheable?

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`, the transaction an idempotent request runs in."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  defdelegate in_scope(scope, fun), to: Store

  # API-11
  # API-13
  # API-15
  @doc "Claims an idempotency key inside the caller's scoped transaction; see `Relay.Ingest.Store.idempotency_begin/3`."
  @spec idempotency_begin(String.t(), String.t(), <<_::256>>) ::
          {:created | :in_progress | :conflict, nil} | {:replayed, Store.response()}
  defdelegate idempotency_begin(endpoint, key, fingerprint), to: Store

  # API-14
  @doc "Stores the response of a key claimed in the same transaction; see `Relay.Ingest.Store.idempotency_complete/4`."
  @spec idempotency_complete(String.t(), String.t(), <<_::256>>, Store.response()) ::
          :stored | :not_cacheable | :not_claimed
  defdelegate idempotency_complete(endpoint, key, fingerprint, response), to: Store

  # API-13
  # API-15
  @doc "Runs work that spans several transactions on one held connection; see `Relay.Ingest.Store.idempotency_session/1`."
  @spec idempotency_session((-> result)) :: result when result: term()
  defdelegate idempotency_session(fun), to: Store

  # API-13
  # API-15
  @doc "Holds a claimed key past its transaction; see `Relay.Ingest.Store.idempotency_hold/2`."
  @spec idempotency_hold(String.t(), String.t()) :: {:held, integer()} | :busy
  defdelegate idempotency_hold(endpoint, key), to: Store

  # API-13
  @doc "Releases a held key; see `Relay.Ingest.Store.idempotency_release/1`."
  @spec idempotency_release(integer()) :: boolean()
  defdelegate idempotency_release(lock), to: Store

  @doc "Runs work in a transaction scoped to `scope` for event reads and writes; see `Relay.Repo.in_scope/3`."
  @spec in_event_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  defdelegate in_event_scope(scope, fun), to: EventStore, as: :in_scope

  # API-34
  @doc "Runs `fun` in a savepoint of the current transaction; see `Relay.Ingest.EventStore.savepoint/1`."
  @spec savepoint((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  defdelegate savepoint(fun), to: EventStore

  # API-58
  # INV-60
  @doc "Takes the shared lock of a cancellation key; see `Relay.Ingest.EventStore.cancellation_lock/1`."
  @spec cancellation_lock(String.t()) :: :ok
  defdelegate cancellation_lock(lock), to: EventStore

  # API-51
  # TN-52
  @doc "Consumes quota; see `Relay.Ingest.EventStore.quota_consume/3`."
  @spec quota_consume(String.t(), pos_integer(), 0..15) :: [map()]
  defdelegate quota_consume(message_class, count, shard), to: EventStore

  # API-51
  # TN-52
  @doc "Sets a quota policy; see `Relay.Ingest.EventStore.quota_policy_set/3`."
  @spec quota_policy_set(map(), <<_::256>>, Relay.Actor.t()) ::
          {atom(), pos_integer() | nil, boolean()}
  defdelegate quota_policy_set(policy, digest, actor), to: EventStore

  @doc "Reads the quota usage of the current period; see `Relay.Ingest.EventStore.quota_usage/1`."
  @spec quota_usage(String.t()) :: map()
  defdelegate quota_usage(period), to: EventStore

  # API-19
  # OP-7
  @doc "Records an accepted event; see `Relay.Ingest.EventStore.event_accept/1`."
  @spec event_accept(map()) :: {atom(), Relay.Id.t() | nil, DateTime.t() | nil}
  defdelegate event_accept(event), to: EventStore

  # API-26
  @doc "Clears the event data of a finished event; see `Relay.Ingest.EventStore.event_payload_erase/2`."
  @spec event_payload_erase(Relay.Id.t(), String.t()) :: :erased | :already_erased | :not_terminal
  defdelegate event_payload_erase(event_id, reason), to: EventStore

  # API-16
  # WF-7
  @doc "Accepts the notification of an event's recipient; see `Relay.Ingest.EventStore.notification_accept/1`."
  @spec event_notification_accept(map()) :: {atom(), Relay.Id.t() | nil, Relay.Id.t() | nil}
  defdelegate event_notification_accept(notification), to: EventStore, as: :notification_accept

  # C-30
  @doc "Opens a delivery; see `Relay.Ingest.Store.delivery_open/2`."
  @spec delivery_open(Relay.Id.t(), map()) :: {atom(), Relay.Id.t() | nil}
  defdelegate delivery_open(notification_id, delivery), to: Store

  # INV-2
  # OP-7
  @doc "Appends an outbox event; see `Relay.Ingest.Store.outbox_append/1`."
  @spec outbox_append(map()) :: {:appended, non_neg_integer(), non_neg_integer()}
  defdelegate outbox_append(event), to: Store

  # API-57
  @doc "Cancels an event; see `Relay.Ingest.EventStore.cancel_event/5`."
  @spec cancel_event(Relay.Id.t(), Relay.Id.t(), reason(), pos_integer(), actor()) :: map()
  defdelegate cancel_event(id, event_id, reason, limit, actor), to: EventStore

  # API-57
  @doc "Cancels a notification; see `Relay.Ingest.EventStore.cancel_notification/4`."
  @spec cancel_notification(Relay.Id.t(), Relay.Id.t(), reason(), actor()) :: map()
  defdelegate cancel_notification(id, notification_id, reason, actor), to: EventStore

  # API-57
  # INV-60
  @doc "Cancels by cancellation key; see `Relay.Ingest.EventStore.cancel_by_key/2`."
  @spec cancel_by_key(map(), Relay.Actor.t()) :: map()
  defdelegate cancel_by_key(cancellation, actor), to: EventStore

  # API-58
  @doc "The tombstone that applies to a run; see `Relay.Ingest.EventStore.cancellation_applies/3`."
  @spec cancellation_applies(Relay.Id.t(), Relay.Id.t(), String.t()) :: Relay.Id.t() | nil
  defdelegate cancellation_applies(event_id, recipient_id, channel), to: EventStore

  # API-28
  @doc "Creates a type mapping; see `Relay.Ingest.EventStore.mapping_create/3`."
  @spec mapping_create(map(), <<_::256>>, Relay.Actor.t()) :: {atom(), Relay.Id.t() | nil, term()}
  defdelegate mapping_create(mapping, digest, actor), to: EventStore

  # API-28
  @doc "Replaces a type mapping; see `Relay.Ingest.EventStore.mapping_replace/4`."
  @spec mapping_replace(map(), pos_integer() | nil, <<_::256>>, actor()) :: {atom(), term()}
  defdelegate mapping_replace(mapping, expected_version, digest, actor), to: EventStore

  # API-28
  @doc "Archives a type mapping; see `Relay.Ingest.EventStore.mapping_archive/4`."
  @spec mapping_archive(Relay.Id.t(), pos_integer() | nil, <<_::256>>, Relay.Actor.t()) ::
          {atom(), term()}
  defdelegate mapping_archive(id, expected_version, digest, actor), to: EventStore

  # API-29
  @doc "Resolves a type mapping; see `Relay.Ingest.EventStore.mapping_resolve/2`."
  @spec mapping_resolve(String.t(), String.t()) :: map() | nil
  defdelegate mapping_resolve(type, source), to: EventStore

  @doc "Reads a type mapping; see `Relay.Ingest.EventStore.mapping/1`."
  @spec mapping(Relay.Id.t()) :: map() | nil
  defdelegate mapping(id), to: EventStore

  @doc "Lists type mappings; see `Relay.Ingest.EventStore.mappings/2`."
  @spec mappings(map() | nil, pos_integer()) :: [map()]
  defdelegate mappings(cursor, limit), to: EventStore

  # OP-51
  @doc "Reads stored tenant settings by key; see `Relay.Ingest.EventStore.settings/1`."
  @spec settings([String.t()]) :: %{String.t() => term()}
  defdelegate settings(keys), to: EventStore

  @doc "Reads an event; see `Relay.Ingest.EventStore.event/1`."
  @spec event(Relay.Id.t()) :: map() | nil
  defdelegate event(id), to: EventStore

  @doc "Reads a notification; see `Relay.Ingest.EventStore.notification/1`."
  @spec notification(Relay.Id.t()) :: map() | nil
  defdelegate notification(id), to: EventStore

  @doc "Lists notifications; see `Relay.Ingest.EventStore.notifications/3`."
  @spec notifications(map(), map() | nil, pos_integer()) :: [map()]
  defdelegate notifications(filters, cursor, limit), to: EventStore

  @doc "Reads a delivery; see `Relay.Ingest.EventStore.delivery/1`."
  @spec delivery(Relay.Id.t()) :: map() | nil
  defdelegate delivery(id), to: EventStore

  @doc "Lists the deliveries of a notification; see `Relay.Ingest.EventStore.deliveries/3`."
  @spec deliveries(Relay.Id.t(), map() | nil, pos_integer()) :: [map()]
  defdelegate deliveries(notification_id, cursor, limit), to: EventStore

  @doc "Reads the attempts of a delivery; see `Relay.Ingest.EventStore.attempts/1`."
  @spec attempts(Relay.Id.t()) :: [map()]
  defdelegate attempts(delivery_id), to: EventStore

  @doc "Reads the ledger of a delivery; see `Relay.Ingest.EventStore.ledger/1`."
  @spec ledger(Relay.Id.t()) :: [map()]
  defdelegate ledger(delivery_id), to: EventStore

  # API-20
  @doc "Checks a send request; see `Relay.Ingest.Request.check/2`."
  @spec check_request(map(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  defdelegate check_request(body, context), to: Request, as: :check

  # TN-9
  @doc "Reads the platform product of the scope's tenant; see `Relay.Ingest.EventStore.platform_product/0`."
  @spec platform_product() :: String.t() | nil
  defdelegate platform_product(), to: EventStore

  # OP-51
  @doc "Reads the installation default send mode; see `Relay.Ingest.EventStore.installation_send_mode/0`."
  @spec installation_send_mode() :: {:ok, String.t() | nil} | {:error, term()}
  defdelegate installation_send_mode(), to: EventStore

  # OP-51
  @doc "Resolves a send mode with the installation default (`live` when unset); see `Relay.Ingest.SendMode.resolve/5`."
  @spec send_mode(String.t() | nil, map(), String.t(), String.t(), String.t() | nil) ::
          SendMode.mode()
  def send_mode(requested, settings, category, channel, installation \\ nil),
    do: SendMode.resolve(requested, settings, category, channel, installation || "live")

  # OP-51
  @doc "The settings keys of a send mode; see `Relay.Ingest.SendMode.keys/2`."
  @spec send_mode_keys(String.t(), String.t()) :: [String.t()]
  defdelegate send_mode_keys(category, channel), to: SendMode, as: :keys

  # API-31
  @doc "The derived CloudEvents idempotency key; see `Relay.Ingest.CloudEvents.idempotency_key/2`."
  @spec ce_idempotency_key(String.t(), String.t()) :: String.t()
  defdelegate ce_idempotency_key(source, id), to: CloudEvents, as: :idempotency_key

  # API-31
  @doc "The derived idempotency key of a CloudEvents batch; see `Relay.Ingest.CloudEvents.batch_key/1`."
  @spec ce_batch_key([{String.t(), String.t()}]) :: String.t()
  defdelegate ce_batch_key(pairs), to: CloudEvents, as: :batch_key

  # API-28
  @doc "The derived CloudEvents dedup key; see `Relay.Ingest.CloudEvents.dedup_key/2`."
  @spec ce_dedup_key(String.t(), String.t()) :: String.t()
  defdelegate ce_dedup_key(source, id), to: CloudEvents, as: :dedup_key

  # API-28
  @doc "The stored digest of a CloudEvents key; see `Relay.Ingest.CloudEvents.key_digest/2`."
  @spec ce_key_digest(String.t(), String.t()) :: <<_::256>>
  defdelegate ce_key_digest(source, id), to: CloudEvents, as: :key_digest

  # API-28
  @doc "Reads a binary mode CloudEvent; see `Relay.Ingest.CloudEvents.from_binary/2`."
  @spec ce_from_binary([{String.t(), String.t()}], term()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  defdelegate ce_from_binary(headers, body), to: CloudEvents, as: :from_binary

  # MD-16
  @doc "Maps a CloudEvent to a native event request; see `Relay.Ingest.CloudEvents.map_event/2`."
  @spec ce_map(map(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  defdelegate ce_map(event, mapping), to: CloudEvents, as: :map_event

  # MD-16
  @doc "Reads the value at a JSON Pointer; see `Relay.Ingest.Pointer.get/2`."
  @spec pointer_get(term(), String.t()) :: {:ok, term()} | :error
  defdelegate pointer_get(document, pointer), to: Pointer, as: :get
end
