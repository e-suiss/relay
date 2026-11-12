defmodule Relay.Inbox do
  @moduledoc """
  The inbox, badges and the realtime feed, on top of the durable record core shared with agent and API client mailboxes (`Relay.Inbox.Mailbox`). Other contexts use only the functions of this module.

  The human inbox is its own store (IN-2): an `in_app` delivery writes one item per recipient and notification (IN-5), a digest updates the item of its group instead of opening a new one (WF-29), and the item, the recipient's counters and the stream publication commit in one transaction (IN-18, IN-25). Every change takes the next `(epoch, seq)` of the recipient's mailbox stream (IN-1, IN-22), so a reader continues from a cursor with `changes/4` and the outbox dispatcher signals the stream after commit. Item content is stored rendered and sealed under the recipient's subject key; the content opener (`config :relay, Relay.Inbox, opener: Module`, by default `Relay.Inbox.Live`) unseals it after the read transaction (IN-44).

  Client writes are state intents (IN-12): monotone ones apply unconditionally, `unread`, `unarchive` and `unsnooze` only at the current `state_version`, else `:conflict` with the current state.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Inbox.Cursor
  alias Relay.Inbox.Item
  alias Relay.Inbox.Mailbox
  alias Relay.Inbox.Realtime
  alias Relay.Inbox.Store
  alias Relay.Inbox.Timer

  @opener Relay.Inbox.Live
  @statuses [:inbox, :unread, :archived, :snoozed, :all]
  @ops ~w(seen read unread archive unarchive hide snooze unsnooze)

  @type counters :: %{
          unseen: non_neg_integer(),
          unread: non_neg_integer(),
          total: non_neg_integer(),
          version: non_neg_integer()
        }
  @type change :: %{
          type: :created | :updated | :removed,
          item_id: Relay.Id.t(),
          seq: pos_integer(),
          state_version: pos_integer(),
          item: map()
        }
  @type page :: %{
          changes: [change()],
          cursor: Cursor.t(),
          counters: counters(),
          has_more: boolean(),
          truncated: boolean()
        }
  @type snapshot :: %{
          items: [map()],
          has_more: boolean(),
          next: {DateTime.t(), Relay.Id.t()} | nil,
          counters: counters(),
          cursor: Cursor.t()
        }
  @type intent :: %{
          required(:op) => String.t(),
          optional(:base_state_version) => integer() | nil,
          optional(:snooze_until) => DateTime.t() | nil
        }

  # AG-64
  # IN-1
  @doc "Opens the owner's mailbox if it has none; see `Relay.Inbox.Mailbox.ensure/3`."
  @spec ensure_mailbox(Relay.Scope.t(), Mailbox.owner_kind(), Relay.Id.t()) ::
          {:ok, term()} | {:error, term()}
  defdelegate ensure_mailbox(scope, owner_kind, owner_ref), to: Mailbox, as: :ensure

  # C-68
  @doc "Appends a record to a mailbox; see `Relay.Inbox.Mailbox.append/2`."
  @spec append(Relay.Scope.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate append(scope, record), to: Mailbox

  # IN-22
  @doc "Reads records after a sequence number; see `Relay.Inbox.Mailbox.read/5`."
  @spec read(Relay.Scope.t(), Relay.Id.t(), pos_integer(), non_neg_integer(), pos_integer()) ::
          {:ok, Mailbox.page()} | {:resync_required, map()} | :not_found | {:error, term()}
  defdelegate read(scope, mailbox_id, epoch, since_seq, limit), to: Mailbox

  # AG-22
  @doc "Leases records; see `Relay.Inbox.Mailbox.lease/5`."
  @spec lease(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defdelegate lease(scope, mailbox_id, holder, max, opts), to: Mailbox

  # AG-21
  @doc "Acknowledges leased records; see `Relay.Inbox.Mailbox.ack/4`."
  @spec ack(Relay.Scope.t(), Relay.Id.t(), [Relay.Id.t()], String.t()) ::
          {:ok, [{Relay.Id.t(), atom()}]} | {:error, term()}
  defdelegate ack(scope, mailbox_id, record_ids, holder), to: Mailbox

  # IN-22
  @doc "Moves a reader cursor forward; see `Relay.Inbox.Mailbox.advance_cursor/5`."
  @spec advance_cursor(
          Relay.Scope.t(),
          Relay.Id.t(),
          String.t(),
          pos_integer(),
          non_neg_integer()
        ) ::
          {:ok, atom()} | {:error, term()}
  defdelegate advance_cursor(scope, mailbox_id, consumer, epoch, seq), to: Mailbox

  # IN-26
  @doc "Starts a new epoch of a mailbox stream; see `Relay.Inbox.Mailbox.bump_epoch/5`."
  @spec bump_epoch(Relay.Scope.t(), Relay.Id.t(), String.t(), <<_::256>>, Relay.Actor.t()) ::
          {:ok, term()} | {:error, term()}
  defdelegate bump_epoch(scope, mailbox_id, reason, record_digest, actor), to: Mailbox

  # AG-5
  @doc "Changes a mailbox state; see `Relay.Inbox.Mailbox.set_state/4`."
  @spec set_mailbox_state(
          Relay.Scope.t(),
          Relay.Id.t(),
          :active | :suspended | :deleted,
          String.t() | nil
        ) ::
          {:ok, atom()} | {:error, term()}
  defdelegate set_mailbox_state(scope, mailbox_id, state, reason), to: Mailbox, as: :set_state

  # IN-49
  @doc "Checks rendered inbox content against the published limits; see `Relay.Inbox.Item.check/2`."
  @spec check_item(Item.content(), map()) ::
          :ok | {:error, :inbox_item_too_large | :schema_violation, map()}
  defdelegate check_item(content, meta), to: Item, as: :check

  # IN-2
  # IN-5
  # IN-25
  # WF-29
  @doc """
  Writes the item of a rendered `in_app` delivery in its own transaction, with its counters and stream publication, and schedules the item's expiry timer. `attrs`: `:id`, `:delivery_id`, `:category`, `:group_key`, `:severity`, `:tags`, `:content_ct` (sealed by the caller), `:content_key_id`, `:content_digest`, `:locale`, `:dir`, `:activity_count`, `:actor_count`. A delivery that already wrote its item returns `:exists` with it; the commit is the delivery's `delivered` evidence (§14).
  """
  @spec record(Relay.Scope.t(), map()) ::
          {:ok,
           {:created | :updated | :exists, Relay.Id.t(), pos_integer()}
           | :delivery_not_found
           | :not_in_app
           | :recipient_inactive}
          | {:error, term()}
  def record(%Relay.Scope{} = scope, attrs),
    do: Store.in_scope(scope, fn _status -> recorded(scope, Store.deliver(attrs)) end)

  defp recorded(scope, {code, item_id, recipient_id, version, expires_at}) do
    if code != :exists, do: schedule(scope, recipient_id, item_id, expires_at)
    {code, item_id, version}
  end

  defp recorded(_scope, other), do: other

  # IN-12
  # IN-13
  # IN-9
  # INV-7
  @doc """
  Applies one state intent of a subscriber to one item inside the caller's transaction scoped to `scope`. Returns `{:applied | :unchanged | :conflict, state, counters, notification_id}` with the item's state view after the intent (for `:conflict`, the current one), the counters that write left and the item's notification, `:invalid` for an unusable `snooze_until` and `:not_found`.
  """
  @spec apply_intent(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t(), intent()) ::
          {:applied | :unchanged | :conflict, map(), counters(), Relay.Id.t()}
          | :invalid
          | :not_found
  def apply_intent(%Relay.Scope{} = scope, subscriber_id, item_id, %{op: op} = intent)
      when op in @ops do
    base = Map.get(intent, :base_state_version)
    until = Map.get(intent, :snooze_until)

    case Store.intent(subscriber_id, item_id, op, base, until) do
      :not_found ->
        :not_found

      {:invalid, _version, _counters_version} ->
        :invalid

      {code, _version, _counters_version} ->
        if code == :applied and op == "snooze",
          do: schedule(scope, subscriber_id, item_id, until)

        row = Store.item(subscriber_id, item_id)
        state = Item.state_view(row, Relay.Clock.utc_now())
        {code, state, Store.counters(subscriber_id), row["notification_id"]}
    end
  end

  # IN-16
  # API-59
  @doc "Retracts, inside the caller's transaction, the items written for an event's notifications (`event_id`) or for the given notifications: each becomes hidden with reason `retracted`, the counters change and an update is published. Returns how many items were retracted."
  @spec retract(Relay.Id.t() | nil, [Relay.Id.t()] | nil) :: non_neg_integer()
  def retract(event_id, notification_ids) when event_id != nil or notification_ids != nil,
    do: Store.retract(event_id, notification_ids)

  # IN-17
  # IN-9
  @doc "Applies an item's due expiry and snooze end in its own transaction and schedules the next due time; used by `Relay.Inbox.Timer`."
  @spec fire_timer(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, atom()} | {:error, term()}
  def fire_timer(%Relay.Scope{} = scope, recipient_id, item_id) do
    Store.in_scope(scope, fn _status ->
      case Store.timer_fire(recipient_id, item_id) do
        {code, next_at} ->
          schedule(scope, recipient_id, item_id, next_at)
          code

        :not_found ->
          :not_found
      end
    end)
  end

  # IN-18
  # IN-19
  # IN-21
  @doc "The subscriber's absolute, versioned counters: `unseen`, `unread`, `total` and `version`."
  @spec counters(Relay.Scope.t(), Relay.Id.t()) :: {:ok, counters()} | {:error, term()}
  def counters(%Relay.Scope{} = scope, subscriber_id),
    do: Store.in_scope(scope, fn _status -> Store.counters(subscriber_id) end)

  # IN-29
  # IN-30
  # IN-28
  @doc """
  The cold sync of a subscriber: the stream position, the counters and the first page of items (or the page after `:after`), read in that order so every change after the position reaches the reader again through `changes/4`. Options: `:limit` (1 to 100, default 50), `:after` (`{last_activity_at, item_id}` of the last item seen), `:status` (`:inbox` by default, `:unread`, `:archived`, `:snoozed` or `:all`), `:category`, `:tag`. Items are full views with their content.
  """
  @spec snapshot(Relay.Scope.t(), Relay.Id.t(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def snapshot(%Relay.Scope{} = scope, subscriber_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)
    status = Keyword.get(opts, :status, :inbox)
    true = status in @statuses
    filters = %{status: status, category: opts[:category], tag: opts[:tag]}

    read = fn _status ->
      head = Store.head(subscriber_id)
      counters = Store.counters(subscriber_id)
      rows = Store.list(subscriber_id, filters, opts[:after], limit + 1)
      {head, counters, rows}
    end

    with {:ok, {head, counters, rows}} <- Store.in_scope(scope, read) do
      {page, rest} = Enum.split(rows, limit)
      last = List.last(page)

      {:ok,
       %{
         items: views(scope, page),
         has_more: rest != [],
         next: if(rest != [], do: {last["last_activity_at"], last["id"]}),
         counters: counters,
         cursor: %{epoch: head.epoch, seq: head.seq}
       }}
    end
  end

  # IN-5
  @doc "One visible item of a subscriber as a full view; a hidden or expired item and another subscriber's item are `:not_found`."
  @spec get(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def get(%Relay.Scope{} = scope, subscriber_id, item_id) do
    case Store.in_scope(scope, fn _status -> Store.item(subscriber_id, item_id) end) do
      {:ok, nil} ->
        :not_found

      {:ok, row} ->
        if Item.removed?(row, Relay.Clock.utc_now()),
          do: :not_found,
          else: {:ok, hd(views(scope, [row]))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # IN-22
  # IN-29
  # INV-35
  @doc """
  The delta sync of a subscriber: the items created, updated and removed (hidden, retracted or expired) after `cursor`, in stream order, at most `limit` (1 to 500), each with its full view (`removed` ones with their state view only), the next cursor and the counters. `has_more` says another page follows; `truncated` says more than 500 changes wait, so the reader should start over with a cold sync instead of paging. A `nil` cursor, another epoch or a position outside the stream is `{:resync_required, %{reason, cursor, counters}}` with the current position. `changes/4` is its realtime source form.
  """
  @spec delta(Relay.Scope.t(), Relay.Id.t(), Cursor.t() | nil, pos_integer()) ::
          {:ok, page()} | {:resync_required, map()} | {:error, term()}
  def delta(%Relay.Scope{} = scope, subscriber_id, cursor, limit \\ 500) do
    cap = Item.limits()["changes_max"]
    limit = limit |> max(1) |> min(cap)

    read = fn _status ->
      head = Store.head(subscriber_id)

      case position(cursor, head) do
        :ok ->
          rows = Store.changed(subscriber_id, head.epoch, cursor.seq, limit + 1)
          waiting = Store.changed_count(subscriber_id, head.epoch, cursor.seq, cap + 1)
          {:ok, head, rows, waiting > cap, Store.counters(subscriber_id)}

        {:resync, reason} ->
          {:resync, reason, head, Store.counters(subscriber_id)}
      end
    end

    case Store.in_scope(scope, read) do
      {:ok, {:ok, head, rows, truncated, counters}} ->
        {:ok, page(scope, {head, cursor.seq}, rows, limit, truncated, counters)}

      {:ok, {:resync, reason, head, counters}} ->
        cursor = %{epoch: head.epoch, seq: head.seq}
        {:resync_required, %{reason: reason, cursor: cursor, counters: counters}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp position(nil, _head), do: {:resync, "position_out_of_range"}

  defp position(%{epoch: epoch}, %{epoch: current}) when epoch != current,
    do: {:resync, "epoch_changed"}

  defp position(%{seq: seq}, %{seq: head, floor: floor}) when seq > head or seq < floor,
    do: {:resync, "position_out_of_range"}

  defp position(_cursor, _head), do: :ok

  defp page(scope, {head, since}, rows, limit, truncated, counters) do
    {rows, rest} = Enum.split(rows, limit)
    now = Relay.Clock.utc_now()
    {removed, kept} = Enum.split_with(rows, &Item.removed?(&1, now))
    views = Map.new(Enum.zip(Enum.map(kept, & &1["id"]), views(scope, kept)))
    removed_ids = MapSet.new(removed, & &1["id"])

    changes =
      for row <- rows do
        removed? = MapSet.member?(removed_ids, row["id"])

        %{
          type: change_type(row, removed?, head.epoch, since),
          item_id: row["id"],
          seq: row["change_seq"],
          state_version: row["state_version"],
          item: if(removed?, do: Item.state_view(row, now), else: Map.fetch!(views, row["id"]))
        }
      end

    last = Enum.reduce(rows, head.seq, &max(&1["change_seq"], &2))
    seq = if rest == [], do: last, else: List.last(rows)["change_seq"]

    %{
      changes: changes,
      cursor: %{epoch: head.epoch, seq: seq},
      counters: counters,
      has_more: rest != [],
      truncated: truncated
    }
  end

  defp change_type(_row, true, _epoch, _since), do: :removed

  defp change_type(%{"created_epoch" => epoch, "created_seq" => seq}, false, epoch, since)
       when seq > since,
       do: :created

  defp change_type(_row, false, _epoch, _since), do: :updated

  # IN-22
  # IN-24
  @doc "The signal topic of the subscriber's stream, on which the outbox dispatcher announces every committed change; it opens the subscriber's mailbox when it has none."
  @spec signal_topic(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t()} | {:error, term()}
  def signal_topic(%Relay.Scope{} = scope, subscriber_id) do
    case Mailbox.ensure(scope, :subscriber, subscriber_id) do
      {:ok, {code, _mailbox_id, stream_key}} when code in [:created, :exists] ->
        opener().signal_topic(scope, stream_key)

      {:ok, other} ->
        {:error, other}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # IN-22
  @doc "The opaque cursor of the subscriber's stream head: reading from it returns only later changes."
  @spec cursor(Relay.Scope.t(), Relay.Id.t()) :: {:ok, String.t()} | {:error, term()}
  def cursor(%Relay.Scope{} = scope, subscriber_id) do
    case Store.in_scope(scope, fn _status -> Store.head(subscriber_id) end) do
      {:ok, head} -> {:ok, Cursor.encode(%{epoch: head.epoch, seq: head.seq})}
      {:error, reason} -> {:error, reason}
    end
  end

  # IN-22
  # IN-26
  # IN-29
  @doc "The realtime source form of `delta/4`: at most `limit` messages after the opaque `cursor`, each `%{t, d, cursor}` in stream order, the next cursor and whether more than 500 changes wait; a cursor that no longer holds is `{:resync_required, reason}`."
  @spec changes(Relay.Scope.t(), Relay.Id.t(), String.t(), pos_integer()) ::
          {:ok, %{changes: [map()], cursor: String.t(), truncated: boolean()}}
          | {:resync_required, String.t()}
          | {:error, term()}
  def changes(%Relay.Scope{} = scope, subscriber_id, cursor, limit) when is_binary(cursor) do
    case Cursor.decode(cursor) do
      {:ok, position} -> source_page(delta(scope, subscriber_id, position, limit))
      :error -> {:resync_required, "position_out_of_range"}
    end
  end

  defp source_page({:ok, page}) do
    changes =
      for {position, message} <- realtime_messages(page),
          do: %{t: message["t"], d: message["d"], cursor: position}

    {:ok, %{changes: changes, cursor: Cursor.encode(page.cursor), truncated: page.truncated}}
  end

  defp source_page({:resync_required, info}), do: {:resync_required, info.reason}
  defp source_page({:error, reason}), do: {:error, reason}

  # IN-26
  # IN-27
  @doc "The realtime messages of a `delta/4` page, each with its stream cursor; see `Relay.Inbox.Realtime.messages/2`."
  @spec realtime_messages(page()) :: [{String.t(), map()}]
  def realtime_messages(page), do: Realtime.messages(page, Relay.Clock.utc_now())

  # IN-22
  @doc "The message telling a reader to resynchronise; see `Relay.Inbox.Realtime.resync/3`."
  @spec resync_message(String.t(), counters()) :: map()
  def resync_message(reason, counters),
    do: Realtime.resync(reason, counters, Relay.Clock.utc_now())

  # IN-22
  @doc "Writes a stream position as an opaque cursor; see `Relay.Inbox.Cursor`."
  @spec encode_cursor(Cursor.t()) :: String.t()
  defdelegate encode_cursor(cursor), to: Cursor, as: :encode

  # IN-22
  @doc "Reads an opaque stream cursor; see `Relay.Inbox.Cursor`."
  @spec decode_cursor(term()) :: {:ok, Cursor.t()} | :error
  defdelegate decode_cursor(text), to: Cursor, as: :decode

  # IN-44
  defp views(_scope, []), do: []

  defp views(scope, rows) do
    now = Relay.Clock.utc_now()
    contents = opener().open(scope, rows)
    for {row, content} <- Enum.zip(rows, contents), do: Item.view(row, content, now)
  end

  defp opener,
    do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:opener, @opener)

  # IN-17
  # WF-43
  defp schedule(_scope, _recipient_id, _item_id, nil), do: :ok

  defp schedule(scope, recipient_id, item_id, %DateTime{} = at) do
    args =
      scope
      |> Relay.Scope.to_job_args()
      |> Map.put("recipient_id", Relay.Id.to_string(recipient_id))
      |> Map.put("item_id", Relay.Id.to_string(item_id))

    Store.insert_job!(Timer.new(args, scheduled_at: Relay.Clock.wall_time(scope, at)))
  end
end
