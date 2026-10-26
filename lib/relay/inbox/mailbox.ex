defmodule Relay.Inbox.Mailbox do
  @moduledoc """
  The durable record core shared by every recipient kind (C-68, IN-1, MD-15, AG-64). An owner — a subscriber, an agent or an API client — has one mailbox, opened lazily by its first record, waitpoint or early response. Every record takes the next `(epoch, seq)` of the mailbox stream (`mailbox:<id>`) in the transaction that writes it, together with its `mailbox.record_appended` outbox event, so sequence order is commit order and a rolled back writer leaves no gap (C-71, OP-5, AG-24).

  Readers fill gaps with `since`: `read/5` returns records after a sequence number in order, at most the replay cap of 500 per call, and tells the reader to resynchronise when the epoch changed or the position is outside the stream (IN-22). Pushes, webhooks and signals are hints only; the state is in the records (INV-35). The outbox dispatcher publishes the stream's latest sequence on the stream signal after commit.

  Agent and API client mailboxes are also consumed with leases: `lease/5` hands out available records and those whose lease expired, counting deliveries and dead-lettering a record past the tenant's limit; `ack/4` confirms them (AG-21, AG-22). Delivery is at least once.
  """

  alias Relay.Inbox.MailboxStore

  @replay_cap 500

  @type owner_kind :: :subscriber | :agent | :api_client
  @type page :: %{
          records: [map()],
          epoch: pos_integer(),
          head_seq: non_neg_integer(),
          has_more: boolean(),
          truncated: boolean()
        }

  # IN-29
  # L-43
  @doc "Most records one `read/5` call returns."
  @spec replay_cap() :: pos_integer()
  def replay_cap, do: @replay_cap

  # AG-64
  # IN-1
  @doc "Opens the owner's mailbox if it has none; returns its identifier and stream key."
  @spec ensure(Relay.Scope.t(), owner_kind(), Relay.Id.t()) ::
          {:ok, {:created | :exists, Relay.Id.t(), String.t()} | :owner_not_found | :tenant_inactive}
          | {:error, term()}
  def ensure(scope, owner_kind, <<_::128>> = owner_ref)
      when owner_kind in [:subscriber, :agent, :api_client] do
    MailboxStore.in_scope(scope, fn _status ->
      MailboxStore.ensure(Relay.Id.generate(), owner_kind, owner_ref)
    end)
  end

  # C-68
  # C-71
  @doc "Appends a record in its own transaction; see `MailboxStore.append/1` for the fields."
  @spec append(Relay.Scope.t(), map()) ::
          {:ok, {:appended, pos_integer(), pos_integer()} | :mailbox_not_found | :mailbox_inactive}
          | {:error, term()}
  def append(scope, record),
    do: MailboxStore.in_scope(scope, fn _status -> MailboxStore.append(record) end)

  # IN-22
  # AG-24
  # INV-35
  @doc """
  Reads the records after `since_seq` of `epoch`, at most `limit` (1 to 500). Returns `{:ok, page}` or `{:resync_required, %{epoch, head_seq, floor}}` when the reader must start over from a cold sync. `has_more` says more records follow this page; `truncated` says the gap is longer than the replay cap, so the reader should resynchronise instead of paging.
  """
  @spec read(Relay.Scope.t(), Relay.Id.t(), pos_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, page()} | {:resync_required, map()} | :not_found | {:error, term()}
  def read(scope, mailbox_id, epoch, since_seq, limit \\ @replay_cap)
      when is_integer(epoch) and is_integer(since_seq) and is_integer(limit) and limit in 1..500 do
    MailboxStore.in_scope(scope, fn _status ->
      case MailboxStore.cursor_check(mailbox_id, epoch, since_seq) do
        {:ok, head} ->
          rows = MailboxStore.read_since(mailbox_id, epoch, since_seq, limit + 1)
          {records, more} = Enum.split(rows, limit)

          {:ok,
           %{
             records: records,
             epoch: head.epoch,
             head_seq: head.head_seq,
             has_more: more != [],
             truncated: head.head_seq - since_seq > @replay_cap
           }}

        {:resync_required, head} ->
          {:resync_required, head}

        :not_found ->
          :not_found
      end
    end)
    |> unwrap()
  end

  # C-68
  # AG-22
  @doc "Leases at most `max` records (1 to 100) for `lease_ms` to `holder`; a record past `max_deliveries` is dead-lettered instead."
  @spec lease(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def lease(scope, mailbox_id, holder, max, opts) do
    lease_ms = Keyword.fetch!(opts, :lease_ms)
    max_deliveries = Keyword.fetch!(opts, :max_deliveries)

    MailboxStore.in_scope(scope, fn _status ->
      MailboxStore.lease(mailbox_id, holder, max, lease_ms, max_deliveries)
    end)
  end

  # AG-21
  @doc "Acknowledges leased records; a lease taken over by another holder is `:lease_lost`."
  @spec ack(Relay.Scope.t(), Relay.Id.t(), [Relay.Id.t()], String.t()) ::
          {:ok, [{Relay.Id.t(), atom()}]} | {:error, term()}
  def ack(scope, mailbox_id, record_ids, holder),
    do:
      MailboxStore.in_scope(scope, fn _status ->
        MailboxStore.ack(mailbox_id, record_ids, holder)
      end)

  # IN-22
  @doc "Moves a reader cursor forward; a cursor never moves back within an epoch."
  @spec advance_cursor(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, :advanced | :stale | :epoch_mismatch | :not_found} | {:error, term()}
  def advance_cursor(scope, mailbox_id, consumer, epoch, seq),
    do:
      MailboxStore.in_scope(scope, fn _status ->
        MailboxStore.cursor_advance(mailbox_id, consumer, epoch, seq)
      end)

  # IN-26
  @doc "Starts a new epoch of the mailbox stream (an audited operator action); readers resynchronise."
  @spec bump_epoch(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, {:bumped, pos_integer()} | :not_found} | {:error, term()}
  def bump_epoch(scope, mailbox_id, reason, record_digest, actor),
    do:
      MailboxStore.in_scope(scope, fn _status ->
        MailboxStore.epoch_bump(mailbox_id, reason, record_digest, actor)
      end)

  # AG-5
  @doc "Suspends, reactivates or deletes a mailbox; records stay."
  @spec set_state(Relay.Scope.t(), Relay.Id.t(), :active | :suspended | :deleted, String.t() | nil) ::
          {:ok, :changed | :unchanged | :not_found} | {:error, term()}
  def set_state(scope, mailbox_id, state, reason \\ nil),
    do:
      MailboxStore.in_scope(scope, fn _status ->
        MailboxStore.set_state(mailbox_id, state, reason)
      end)

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, _} = error), do: error
end
