defmodule Relay.Inbox.MailboxStore do
  @moduledoc """
  Data access for the durable record core: mailboxes, their sequence-numbered records and reader cursors, through the `relay_fn.mailbox_*` functions inside `Relay.Repo.in_scope/3`.
  """

  alias Relay.Actor
  alias Relay.Repo

  @owner_kinds %{subscriber: "subscriber", agent: "agent", api_client: "api_client"}
  @kinds %{message: "message", waitpoint_event: "waitpoint_event", early_event: "early_event"}

  # TN-13 (2)
  @doc "Runs work in a transaction scoped to `scope`; see `Relay.Repo.in_scope/3`."
  @spec in_scope(Relay.Scope.t(), (atom() -> term())) :: {:ok, term()} | {:error, term()}
  def in_scope(scope, fun), do: Repo.in_scope(scope, fun)

  # AG-64
  @doc "Opens the owner's mailbox if it has none and returns it."
  @spec ensure(Relay.Id.t(), atom(), Relay.Id.t()) ::
          {:created | :exists, Relay.Id.t(), String.t()} | :owner_not_found | :tenant_inactive
  def ensure(id, owner_kind, owner_ref) do
    [row] =
      Repo.call!("relay_fn.mailbox_ensure", [id, Map.fetch!(@owner_kinds, owner_kind), owner_ref])

    case Repo.code!(row["result"], [:created, :exists, :owner_not_found, :tenant_inactive]) do
      code when code in [:created, :exists] -> {code, row["mailbox_id"], row["stream_key"]}
      other -> other
    end
  end

  # C-71
  # OP-5
  @doc "Appends a record; its position is the stream sequence taken in this transaction."
  @spec append(map()) ::
          {:appended, pos_integer(), pos_integer()} | :mailbox_not_found | :mailbox_inactive
  def append(record) do
    [row] =
      Repo.call!("relay_fn.mailbox_append", [
        record.id,
        record.mailbox_id,
        Map.fetch!(@kinds, Map.get(record, :kind, :message)),
        record.event_type,
        Map.get(record, :correlation_key),
        Map.get(record, :waitpoint_id),
        Map.get(record, :source_event_id),
        Map.get(record, :payload_ct),
        Map.get(record, :payload_subject_key_id),
        Map.get(record, :payload_tenant_key_id),
        record.payload_digest,
        Map.get(record, :traceparent)
      ])

    case Repo.code!(row["result"], [:appended, :mailbox_not_found, :mailbox_inactive]) do
      :appended -> {:appended, row["epoch"], row["seq"]}
      other -> other
    end
  end

  # IN-22
  @doc "Checks a reader position against the mailbox stream."
  @spec cursor_check(Relay.Id.t(), integer(), integer()) ::
          {:ok | :resync_required,
           %{epoch: pos_integer(), head_seq: non_neg_integer(), floor: non_neg_integer()}}
          | :not_found
  def cursor_check(mailbox_id, epoch, since_seq) do
    [row] = Repo.call!("relay_fn.mailbox_cursor_check", [mailbox_id, epoch, since_seq])

    case Repo.code!(row["result"], [:ok, :resync_required, :not_found]) do
      :not_found ->
        :not_found

      code ->
        {code,
         %{
           epoch: row["current_epoch"],
           head_seq: row["head_seq"],
           floor: row["replay_floor_seq"]
         }}
    end
  end

  # IN-22
  # OP-5
  @doc "Reads at most `limit` records after `since_seq` of an epoch, in sequence order."
  @spec read_since(Relay.Id.t(), pos_integer(), non_neg_integer(), pos_integer()) :: [map()]
  def read_since(mailbox_id, epoch, since_seq, limit) do
    for row <- Repo.call!("relay_fn.mailbox_read_since", [mailbox_id, epoch, since_seq, limit]),
        do: record(row)
  end

  # C-68
  # AG-22
  @doc "Leases available records and records whose lease expired."
  @spec lease(Relay.Id.t(), String.t(), pos_integer(), pos_integer(), pos_integer()) :: [map()]
  def lease(mailbox_id, holder, max, lease_ms, max_deliveries) do
    for row <-
          Repo.call!("relay_fn.mailbox_lease", [
            mailbox_id,
            holder,
            max,
            lease_ms,
            max_deliveries
          ]),
        do: Map.put(record(row), :delivery_count, row["delivery_count"])
  end

  # AG-21
  @doc "Acknowledges leased records of a holder."
  @spec ack(Relay.Id.t(), [Relay.Id.t()], String.t()) :: [
          {Relay.Id.t(), :acked | :already_acked | :lease_lost | :not_found}
        ]
  def ack(mailbox_id, record_ids, holder) do
    for row <- Repo.call!("relay_fn.mailbox_ack", [mailbox_id, record_ids, holder]),
        do:
          {row["record_id"],
           Repo.code!(row["result"], [:acked, :already_acked, :lease_lost, :not_found])}
  end

  # IN-22
  @doc "Moves a reader cursor forward."
  @spec cursor_advance(Relay.Id.t(), String.t(), pos_integer(), non_neg_integer()) ::
          :advanced | :stale | :epoch_mismatch | :not_found
  def cursor_advance(mailbox_id, consumer, epoch, seq) do
    [row] = Repo.call!("relay_fn.mailbox_cursor_advance", [mailbox_id, consumer, epoch, seq])
    Repo.code!(row["mailbox_cursor_advance"], [:advanced, :stale, :epoch_mismatch, :not_found])
  end

  # IN-26
  @doc "Starts a new epoch of the mailbox stream; readers must resynchronise."
  @spec epoch_bump(Relay.Id.t(), String.t(), <<_::256>>, Actor.t()) ::
          {:bumped, pos_integer()} | :not_found
  def epoch_bump(mailbox_id, reason, digest, %Actor{} = actor) do
    [row] =
      Repo.call!(
        "relay_fn.mailbox_epoch_bump",
        [mailbox_id, reason, digest | Actor.params(actor)]
      )

    case Repo.code!(row["result"], [:bumped, :not_found]) do
      :bumped -> {:bumped, row["epoch"]}
      :not_found -> :not_found
    end
  end

  # AG-5
  @doc "Changes the mailbox state; `deleted` is terminal."
  @spec set_state(Relay.Id.t(), :active | :suspended | :deleted, String.t() | nil) ::
          :changed | :unchanged | :not_found
  def set_state(mailbox_id, state, reason) do
    [row] =
      Repo.call!("relay_fn.mailbox_set_state", [mailbox_id, Atom.to_string(state), reason])

    Repo.code!(row["mailbox_set_state"], [:changed, :unchanged, :not_found])
  end

  defp record(row) do
    %{
      id: row["id"],
      epoch: row["epoch"],
      seq: row["seq"],
      kind: Map.get(row, "kind"),
      event_type: row["event_type"],
      waitpoint_id: row["waitpoint_id"],
      payload_ct: row["payload_ct"],
      payload_subject_key_id: row["payload_subject_key_id"],
      payload_tenant_key_id: row["payload_tenant_key_id"],
      payload_digest: row["payload_digest"],
      delivery_state: Map.get(row, "delivery_state"),
      created_at: Map.get(row, "created_at")
    }
  end
end
