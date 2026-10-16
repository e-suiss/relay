defmodule Relay.Ingest.Store do
  @moduledoc """
  Data access of the accept path: idempotency claims, notification acceptance, delivery opening and outbox appends. Every function runs inside `Relay.Repo.in_scope/3` and is one step of the accept transaction (OP-7).
  """

  alias Relay.Repo

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  @doc "Runs a multi in a transaction scoped to `scope`; see `Relay.Repo.in_scope_multi/3`."
  @spec in_scope_multi(Relay.Scope.t(), Ecto.Multi.t()) ::
          {:ok, map()} | {:error, term()} | {:error, Ecto.Multi.name(), term(), map()}
  def in_scope_multi(scope, multi), do: Repo.in_scope_multi(scope, multi)

  @type response :: %{
          status: 100..599,
          headers: map(),
          body_ct: binary(),
          body_key_id: Relay.Id.t()
        }

  # API-11
  # API-13
  # API-15
  # OP-68 (8)
  @doc "Claims an idempotency key under a transaction lock and looks it up over the last 24 hours."
  @spec idempotency_begin(String.t(), String.t(), <<_::256>>) ::
          {:created | :in_progress | :conflict, nil} | {:replayed, response()}
  def idempotency_begin(endpoint, key, <<_::256>> = fingerprint) do
    [row] = Repo.call!("relay_fn.idempotency_begin", [endpoint, key, fingerprint])

    case Repo.code!(row["result"], [:created, :replayed, :in_progress, :conflict]) do
      :replayed ->
        {:replayed,
         %{
           status: row["response_status"],
           headers: row["response_headers"],
           body_ct: row["response_body_ct"],
           body_key_id: row["response_body_key_id"]
         }}

      other ->
        {other, nil}
    end
  end

  # API-14
  @doc "Stores the response of a claimed key; 400, 401, 403 and 429 are not cacheable."
  @spec idempotency_complete(String.t(), String.t(), <<_::256>>, response()) ::
          :stored | :not_cacheable | :not_claimed
  def idempotency_complete(endpoint, key, fingerprint, response) do
    [row] =
      Repo.call!("relay_fn.idempotency_complete", [
        endpoint,
        key,
        fingerprint,
        response.status,
        response.headers,
        response.body_ct,
        response.body_key_id
      ])

    Repo.code!(row["idempotency_complete"], [:stored, :not_cacheable, :not_claimed])
  end

  # API-16
  # C-29
  # OP-68 (3)
  @doc "Accepts a notification for one recipient; a repeated dedup key returns the first notification."
  @spec notification_accept(map()) ::
          {:created | :duplicate | :recipient_not_found | :subtenant_not_found | :tenant_inactive,
           Relay.Id.t() | nil}
  def notification_accept(n) do
    [row] =
      Repo.call!("relay_fn.notification_accept", [
        n.id,
        n.recipient_id,
        Map.get(n, :subtenant_id),
        n.dedup_key,
        Atom.to_string(n.message_class),
        optional_text(Map.get(n, :security_subtype)),
        Atom.to_string(n.sender_type),
        Map.get(n, :subject_type),
        Map.get(n, :subject_id),
        Map.get(n, :expires_at),
        Map.get(n, :is_test, false),
        Map.get(n, :traceparent)
      ])

    {Repo.code!(row["result"], [
       :created,
       :duplicate,
       :recipient_not_found,
       :subtenant_not_found,
       :tenant_inactive
     ]), row["notification_id"]}
  end

  # C-30
  # OP-2
  # OP-68 (2)
  @doc "Opens a delivery with its opening ledger event; the same notification, channel and target returns the existing delivery."
  @spec delivery_open(Relay.Id.t(), map()) ::
          {:opened
           | :exists
           | :notification_not_found
           | :notification_closed
           | :fallback_invalid
           | :tenant_inactive, Relay.Id.t() | nil}
  def delivery_open(notification_id, d) do
    [row] =
      Repo.call!("relay_fn.delivery_open", [
        d.id,
        notification_id,
        Atom.to_string(d.channel),
        Atom.to_string(d.target_kind),
        Map.get(d, :target_id),
        d.target_key,
        Map.get(d, :provider),
        Map.get(d, :provider_account_id),
        Map.get(d, :fallback_of),
        Atom.to_string(d.decision),
        Map.get(d, :decision_reason),
        Map.get(d, :decision_rule_id),
        Map.get(d, :deferred_until),
        Map.get(d, :traceparent)
      ])

    {Repo.code!(row["result"], [
       :opened,
       :exists,
       :notification_not_found,
       :notification_closed,
       :fallback_invalid,
       :tenant_inactive
     ]), row["delivery_id"]}
  end

  # INV-2
  # OP-5
  # OP-7
  @doc "Appends an outbox event in the writing transaction and returns its stream position."
  @spec outbox_append(map()) :: {:appended, non_neg_integer(), non_neg_integer()}
  def outbox_append(event) do
    [row] =
      Repo.call!("relay_fn.outbox_append", [
        event.id,
        event.event_type,
        event.stream_key,
        event.payload,
        Map.get(event, :traceparent)
      ])

    {Repo.code!(row["result"], [:appended]), row["epoch"], row["seq"]}
  end

  defp optional_text(nil), do: nil
  defp optional_text(value) when is_atom(value), do: Atom.to_string(value)
end
