defmodule Relay.Agents.Mailbox do
  @moduledoc """
  The agent face of the durable record core (C-68, AG-20, AG-64): lease, then acknowledge. An agent and an API client each own one mailbox, opened lazily; its records are sequence-numbered in commit order with their outbox event, so the state is in the records and a push, a webhook or a protocol notification is only a hint to wake up (AG-21).

  `lease/3` hands out the records that wait and those whose lease ran out, oldest first, under a lease identifier of its own; `ack/4` confirms the records that lease still holds. A record that is not acknowledged within the lease is handed out again, so delivery is at least once and the reader deduplicates by the record identifier. A record already delivered once and redelivered the tenant's redelivery count is dead-lettered when it comes up again: it stays in the mailbox, is read through `dead_letters/4` and `mailbox.record_dead_lettered` is written to the outbox in the same transaction (AG-22). The lease duration and the redelivery count are the tenant's `mailbox.lease` setting within the contract's `x-relay-limits` `mailbox` (AG-70); a value outside the bounds never applies.

  `read/4` reads after a position in sequence order and takes no lease; without a position it starts after the acknowledged position, below which every record is acknowledged or dead-lettered (AG-24). `record/3` reads one record by its identifier, the durable handle every hint carries.

  A suspended mailbox hands out no lease and is still read; nothing is ever removed from a mailbox (AG-23, INV-47). The payload of a record stays sealed in the record; this module reads positions and delivery state, and `Relay.Agents.Messages` gives a record its structured message.
  """

  alias Relay.Agents.MailboxStore

  @lease_ms %{
    default: Relay.Limits.seconds!(["mailbox", "lease_duration", "default"]) * 1000,
    min: Relay.Limits.seconds!(["mailbox", "lease_duration", "min"]) * 1000,
    max: Relay.Limits.seconds!(["mailbox", "lease_duration", "max"]) * 1000
  }
  @redeliveries Relay.Limits.fetch!(["mailbox", "redeliveries"])
  @lease_max_records Relay.Limits.fetch!(["mailbox", "lease_max_records"])
  @read_max 100

  @type owner :: MailboxStore.owner()
  @type position :: %{epoch: pos_integer(), seq: non_neg_integer()}
  @type settings :: %{lease_ms: pos_integer(), max_redeliveries: pos_integer()}
  @type refusal :: :not_found | :owner_not_found | :tenant_inactive
  @type view :: %{
          id: Relay.Id.t(),
          owner: owner(),
          state: :active | :suspended,
          head: position(),
          acked: position(),
          settings: settings(),
          created_at: DateTime.t()
        }
  @type lease :: %{lease_id: String.t(), lease_until: DateTime.t() | nil, records: [map()]}
  @type page :: %{records: [map()], position: position(), has_more: boolean()}

  # AG-53
  # AG-70
  @doc "The limits of the agent face as the contract publishes them: the lease duration in milliseconds and the redelivery count, each with its default and bounds, and the most records one lease request takes."
  @spec limits() :: %{
          lease_ms: %{default: pos_integer(), min: pos_integer(), max: pos_integer()},
          redeliveries: %{default: pos_integer(), min: pos_integer(), max: pos_integer()},
          lease_max_records: pos_integer()
        }
  def limits do
    %{
      lease_ms: @lease_ms,
      redeliveries: %{
        default: @redeliveries["default"],
        min: @redeliveries["min"],
        max: @redeliveries["max"]
      },
      lease_max_records: @lease_max_records
    }
  end

  # AG-22
  # AG-70
  @doc "The lease duration and the redelivery count of a stored `mailbox.lease` value: a field that is missing or outside the contract's bounds takes the default."
  @spec settings(term()) :: settings()
  def settings(stored) do
    stored = if is_map(stored), do: stored, else: %{}
    lease = @lease_ms
    count = @redeliveries

    %{
      lease_ms: within(ms(stored["lease_seconds"]), lease.min, lease.max, lease.default),
      max_redeliveries:
        within(stored["max_redeliveries"], count["min"], count["max"], count["default"])
    }
  end

  defp ms(seconds) when is_integer(seconds), do: seconds * 1000
  defp ms(_other), do: nil

  defp within(value, min, max, _default) when is_integer(value) and value >= min and value <= max,
    do: value

  defp within(_value, _min, _max, default), do: default

  # AG-20
  # AG-64
  @doc "Opens the owner's mailbox if it has none and reads it in a transaction of its own; see `open_in/1`."
  @spec open(Relay.Scope.t(), owner()) :: {:ok, view()} | {:error, refusal() | term()}
  def open(scope, owner), do: scoped(scope, fn -> open_in(owner) end)

  # AG-20
  # AG-23
  # AG-64
  @doc "Opens the owner's mailbox if it has none, inside the caller's scoped transaction, and reads it: its state, the head of its stream, the acknowledged position and the settings in force. A mailbox deleted by an erasure or at the end of its retention is `:not_found`; its records stay."
  @spec open_in(owner()) :: {:ok, view()} | {:error, refusal()}
  def open_in(owner) do
    case MailboxStore.ensure(Relay.Id.generate(), owner) do
      {:ok, _mailbox_id} -> owner |> MailboxStore.by_owner() |> viewed()
      refusal -> {:error, refusal}
    end
  end

  defp viewed(%{"state" => state} = mailbox) when state in ["active", "suspended"] do
    id = mailbox["id"]
    {_code, head} = MailboxStore.cursor_check(id, 1, 0)

    {:ok,
     %{
       id: id,
       owner: {owner_kind(mailbox["owner_kind"]), mailbox["owner_ref"]},
       state: if(state == "active", do: :active, else: :suspended),
       head: %{epoch: head.epoch, seq: head.head_seq},
       acked: acked(id, head.epoch, head.head_seq),
       settings: settings(MailboxStore.setting()),
       created_at: mailbox["created_at"]
     }}
  end

  defp viewed(_deleted_or_missing), do: {:error, :not_found}

  defp owner_kind("agent"), do: :agent
  defp owner_kind("api_client"), do: :api_client

  defp acked(mailbox_id, epoch, head_seq) do
    case MailboxStore.first_pending(mailbox_id, epoch) do
      nil -> %{epoch: epoch, seq: head_seq}
      seq -> %{epoch: epoch, seq: seq - 1}
    end
  end

  # AG-20
  # AG-22
  @doc "Leases records in a transaction of its own; see `lease_in/2`."
  @spec lease(Relay.Scope.t(), owner(), pos_integer()) ::
          {:ok, lease()} | {:error, refusal() | :inactive | term()}
  def lease(scope, owner, max), do: scoped(scope, fn -> lease_in(owner, max) end)

  # AG-20
  # AG-22
  # AG-24
  # T-11
  @doc "Leases at most `max` records (1 to the contract's `mailbox.lease_max_records`) of the owner's mailbox inside the caller's scoped transaction, oldest first, for the tenant's lease duration. The database decides when a lease has run out, on its business time, so a `test` scope's virtual clock moves it (TN-8). A record past the tenant's redelivery count is dead-lettered instead of leased. `:lease_until` is `nil` when no record was taken. A suspended mailbox is `:inactive`."
  @spec lease_in(owner(), pos_integer()) :: {:ok, lease()} | {:error, refusal() | :inactive}
  def lease_in(owner, max) when is_integer(max) and max in 1..@lease_max_records do
    with {:ok, mailbox} <- open_in(owner),
         :ok <- active(mailbox) do
      lease_id = Base.encode16(Relay.Id.generate(), case: :lower)
      %{lease_ms: lease_ms, max_redeliveries: redeliveries} = mailbox.settings
      records = MailboxStore.lease(mailbox.id, lease_id, max, lease_ms, redeliveries + 1)
      {:ok, %{lease_id: lease_id, lease_until: lease_until(records), records: records}}
    end
  end

  defp lease_until([%{"lease_until" => until} | _rest]), do: until
  defp lease_until([]), do: nil

  defp active(%{state: :active}), do: :ok
  defp active(_suspended), do: {:error, :inactive}

  # AG-20
  @doc "Acknowledges records in a transaction of its own; see `ack_in/3`."
  @spec ack(Relay.Scope.t(), owner(), String.t(), [Relay.Id.t()]) ::
          {:ok, %{results: [{Relay.Id.t(), atom()}], acked: position()}}
          | {:error, refusal() | term()}
  def ack(scope, owner, lease_id, record_ids),
    do: scoped(scope, fn -> ack_in(owner, lease_id, record_ids) end)

  # AG-20
  # AG-21
  @doc "Acknowledges the records the lease `lease_id` holds in the owner's mailbox, inside the caller's scoped transaction. Each record has its result: `:acked`, `:already_acked`, `:lease_lost` when another lease holds it or it is dead-lettered, or `:not_found`. Returns the results in the order given with the acknowledged position."
  @spec ack_in(owner(), String.t(), [Relay.Id.t()]) ::
          {:ok, %{results: [{Relay.Id.t(), atom()}], acked: position()}} | {:error, refusal()}
  def ack_in(owner, lease_id, record_ids) when is_binary(lease_id) and is_list(record_ids) do
    with {:ok, mailbox} <- open_in(owner) do
      results = Map.new(MailboxStore.ack(mailbox.id, record_ids, lease_id))
      ordered = for id <- Enum.uniq(record_ids), do: {id, Map.fetch!(results, id)}
      %{epoch: epoch, seq: head_seq} = mailbox.head
      {:ok, %{results: ordered, acked: acked(mailbox.id, epoch, head_seq)}}
    end
  end

  # AG-20
  # AG-24
  @doc "Reads the records of the owner's mailbox after `since` (`nil`: the acknowledged position) in sequence order, at most `limit` (1 to 100), in a transaction of its own. Returns the page with the position to continue from, or `{:resync_required, position}` with the acknowledged position when `since` is of another epoch or outside the stream."
  @spec read(Relay.Scope.t(), owner(), position() | nil, pos_integer()) ::
          {:ok, page()} | {:resync_required, position()} | {:error, refusal() | term()}
  def read(scope, owner, since, limit) when is_integer(limit) and limit in 1..@read_max do
    scoped(scope, fn ->
      with {:ok, mailbox} <- open_in(owner), do: read_from(mailbox, since || mailbox.acked, limit)
    end)
  end

  defp read_from(mailbox, %{epoch: epoch, seq: seq}, limit) do
    case MailboxStore.cursor_check(mailbox.id, epoch, seq) do
      {:ok, _head} ->
        rows = MailboxStore.read_since(mailbox.id, epoch, seq, limit + 1)
        {records, more} = Enum.split(rows, limit)

        position =
          if more == [], do: mailbox.head, else: %{epoch: epoch, seq: List.last(records)["seq"]}

        {:ok, %{records: records, position: position, has_more: more != []}}

      _resync_or_gone ->
        {:resync_required, mailbox.acked}
    end
  end

  # AG-21
  @doc "Reads one record by its identifier in a transaction of its own: a record of the owner's mailbox, or with `:any` a record of any agent or API client mailbox of the scope. `nil` when there is none."
  @spec record(Relay.Scope.t(), Relay.Id.t(), owner() | :any) ::
          {:ok, map() | nil} | {:error, term()}
  def record(scope, record_id, whose) do
    MailboxStore.in_scope(scope, fn _status ->
      with %{} = record <- MailboxStore.record(record_id),
           %{} = mailbox <- MailboxStore.by_id(record["mailbox_id"]),
           true <- whose == :any or owned?(mailbox, whose) do
        record
      else
        _none -> nil
      end
    end)
  end

  defp owned?(mailbox, {kind, ref}),
    do: mailbox["owner_kind"] == Atom.to_string(kind) and mailbox["owner_ref"] == ref

  # AG-22
  # AG-23
  @doc "A page of the dead-lettered records of a mailbox, newest first, in a transaction of its own: the owner's own mailbox, or with `{:id, mailbox_id}` any agent or API client mailbox of the scope, also a suspended or deleted one. Returns at most `limit + 1` rows for the caller's list envelope."
  @spec dead_letters(
          Relay.Scope.t(),
          owner() | {:id, Relay.Id.t()},
          map() | nil,
          pos_integer()
        ) :: {:ok, [map()]} | {:error, :not_found | term()}
  def dead_letters(scope, whose, cursor, limit) do
    scoped(scope, fn ->
      case {whose, target(whose)} do
        {_whose, %{"id" => id}} -> {:ok, MailboxStore.dead_letters(id, cursor, limit)}
        {{:id, _mailbox_id}, nil} -> {:error, :not_found}
        {_owner, nil} -> {:ok, []}
      end
    end)
  end

  defp target({:id, mailbox_id}), do: MailboxStore.by_id(mailbox_id)
  defp target(owner), do: MailboxStore.by_owner(owner)

  defp scoped(scope, fun) do
    case MailboxStore.in_scope(scope, fn _status -> fun.() end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end
end
