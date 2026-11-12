defmodule Relay.Inbox do
  @moduledoc """
  The inbox, badges and the realtime feed, on top of the durable record core shared with agent and API client mailboxes (`Relay.Inbox.Mailbox`). Other contexts use only the functions of this module.

  The human inbox is its own store (IN-2): an `in_app` delivery writes one item per recipient and notification (IN-5), a digest updates the item of its group instead of opening a new one (WF-29), and the item, the recipient's counters and the stream publication commit in one transaction (IN-18, IN-25). Every change takes the next `(epoch, seq)` of the recipient's mailbox stream (IN-1, IN-22), so a reader continues from a cursor with `changes/4` and the outbox dispatcher signals the stream after commit. Item content is stored rendered and sealed under the recipient's subject key; the content opener (`config :relay, Relay.Inbox, opener: Module`, by default `Relay.Inbox.Live`) unseals it after the read transaction (IN-44).

  Client writes are state intents (IN-12): monotone ones apply unconditionally, `unread`, `unarchive` and `unsnooze` only at the current `state_version`, else `:conflict` with the current state. An applied `seen`, `read`, `archive` or `click` is the engagement evidence of the item's delivery (DS-7, DS-12), and a read cancels the pending digest windows of the item's notification (WF-27).

  Announcements (IN-3, C-70) are one record per audience, merged into every list, delta and counter read of the recipients in the audience (`Relay.Inbox.Announcement`); a recipient's state of an announcement is written only when it acts. "Mark all read" (IN-50) reads the scope's unread items in one transaction and stamps a read mark that reads the scope's earlier announcements; other bulk actions run as a chunked job with a status record (IN-14). Counters are reconciled with the items nightly and on a client's report (IN-18, IN-21). Retention keeps the newest visible items in the list and ends the retention of old items by soft deletion and content shredding (IN-44, OP-22). A counter change that no intent caused queues a sync signal to the recipient's devices (IN-35).
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Devices, Relay.Workflow], exports: []

  alias Relay.Inbox.Announcement
  alias Relay.Inbox.AnnouncementTimer
  alias Relay.Inbox.BulkJob
  alias Relay.Inbox.Cursor
  alias Relay.Inbox.Item
  alias Relay.Inbox.Mailbox
  alias Relay.Inbox.Realtime
  alias Relay.Inbox.Store
  alias Relay.Inbox.Timer

  @opener Relay.Inbox.Live
  @statuses [:inbox, :unread, :archived, :snoozed, :all]
  @ops ~w(seen read unread archive unarchive hide snooze unsnooze click)
  @announcement_ops ~w(seen read unread archive unarchive hide click)
  @retention Relay.Limits.fetch!(["inbox", "retention"])
  @bulk_chunk Relay.Limits.fetch!(["inbox", "bulk_chunk_size"])
  @engagement %{"seen" => "seen", "read" => "read", "archive" => "archived"}

  @type counters :: %{
          unseen: non_neg_integer(),
          unread: non_neg_integer(),
          total: non_neg_integer(),
          version: non_neg_integer()
        }
  @type change :: %{
          type: :created | :updated | :removed,
          item_id: Relay.Id.t(),
          ref: String.t(),
          seq: pos_integer(),
          state_version: pos_integer(),
          item: map(),
          position: Cursor.t()
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
  @type target :: Relay.Id.t() | {:announcement, Relay.Id.t()}
  @type reconciled :: %{
          checked: non_neg_integer(),
          repaired: non_neg_integer(),
          last: Relay.Id.t() | nil
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
  # IN-44
  # IN-35
  @doc """
  Writes the item of a rendered `in_app` delivery in its own transaction, with its counters and stream publication, and schedules the item's expiry timer. `attrs`: `:id`, `:delivery_id`, `:category`, `:group_key`, `:severity`, `:tags`, `:content_ct` (sealed by the caller), `:content_key_id`, `:content_digest`, `:locale`, `:dir`, `:activity_count`, `:actor_count`. A delivery that already wrote its item returns `:exists` with it; the commit is the delivery's `delivered` evidence (§14). A new or updated item takes the recipient's items beyond the tenant's visible window out of the list and the counters, and queues a sync signal to the recipient's devices in the same transaction.
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

  defp recorded(_scope, {:exists, item_id, _recipient_id, version, _expires_at}),
    do: {:exists, item_id, version}

  defp recorded(scope, {code, item_id, recipient_id, version, expires_at}) do
    schedule(scope, recipient_id, item_id, expires_at)
    _ = Store.trim(recipient_id, retention()["visible_items"])
    sync!(scope, recipient_id)
    {code, item_id, version}
  end

  defp recorded(_scope, other), do: other

  # IN-12
  # IN-13
  # IN-9
  # INV-7
  # DS-7
  # WF-27
  # IN-3
  @doc """
  Applies one state intent of a subscriber to one item, or to one announcement (`{:announcement, id}`), inside the caller's transaction scoped to `scope`. Returns `{:applied | :unchanged | :conflict, state, counters, notification_id}` with the state view after the intent (for `:conflict`, the current one), the merged counters and the item's notification (`nil` for an announcement), `:invalid` for an unusable `snooze_until` and `:not_found`. `click` reads the item and records the click. An applied `seen`, `read`, `archive` or `click` of an item is recorded as engagement evidence of its delivery, and an applied read cancels the pending digest windows of its notification.
  """
  @spec apply_intent(Relay.Scope.t(), Relay.Id.t(), target(), intent()) ::
          {:applied | :unchanged | :conflict, map(), counters(), Relay.Id.t() | nil}
          | :invalid
          | :not_found
  def apply_intent(%Relay.Scope{}, subscriber_id, {:announcement, id}, %{op: op} = intent)
      when op in @announcement_ops do
    sql_op = if op == "click", do: "read", else: op

    case Store.announcement_intent(subscriber_id, id, sql_op, intent[:base_state_version]) do
      :not_found ->
        :not_found

      {:invalid, _version} ->
        :invalid

      {code, _version} ->
        row = Store.announcement(subscriber_id, id)
        state = Announcement.state_view(row, Relay.Clock.utc_now())
        {code, state, merged_counters(subscriber_id), nil}
    end
  end

  def apply_intent(%Relay.Scope{}, _subscriber_id, {:announcement, _id}, _intent), do: :invalid

  def apply_intent(%Relay.Scope{} = scope, subscriber_id, item_id, %{op: op} = intent)
      when op in @ops do
    base = Map.get(intent, :base_state_version)
    until = Map.get(intent, :snooze_until)
    sql_op = if op == "click", do: "read", else: op

    case Store.intent(subscriber_id, item_id, sql_op, base, until) do
      :not_found ->
        :not_found

      {:invalid, _version, _counters_version} ->
        :invalid

      {code, _version, _counters_version} ->
        if code == :applied and op == "snooze",
          do: schedule(scope, subscriber_id, item_id, until)

        row = Store.item(subscriber_id, item_id)
        engaged(scope, subscriber_id, row, op, code)
        state = Item.state_view(row, Relay.Clock.utc_now())
        {code, state, merged_counters(subscriber_id), row["notification_id"]}
    end
  end

  defp engaged(scope, subscriber_id, row, "click", code) do
    :recorded = Store.engage(subscriber_id, row["id"], "clicked")
    engaged(scope, subscriber_id, row, "read", code)
  end

  defp engaged(scope, subscriber_id, row, op, :applied) do
    case Map.fetch(@engagement, op) do
      {:ok, kind} ->
        :recorded = Store.engage(subscriber_id, row["id"], kind)
        if op == "read", do: digest_read!(scope, subscriber_id, [row["notification_id"]])

      :error ->
        :ok
    end
  end

  defp engaged(_scope, _subscriber_id, _row, _op, _code), do: :ok

  # IN-16
  # API-59
  # IN-35
  @doc "Retracts, inside the caller's transaction, the items written for an event's notifications (`event_id`) or for the given notifications: each becomes hidden with reason `retracted`, the counters change, an update is published and the devices of every recipient reached get a sync signal. Returns how many items were retracted."
  @spec retract(Relay.Id.t() | nil, [Relay.Id.t()] | nil) :: non_neg_integer()
  def retract(event_id, notification_ids) when event_id != nil or notification_ids != nil do
    recipients = Store.retract_recipients(event_id, notification_ids)
    retracted = Store.retract(event_id, notification_ids)

    if retracted > 0 do
      scope = Store.current_scope()
      Enum.each(recipients, &sync!(scope, &1))
    end

    retracted
  end

  # IN-17
  # IN-9
  # IN-35
  @doc "Applies an item's due expiry and snooze end in its own transaction and schedules the next due time; a change queues a sync signal to the recipient's devices. Used by `Relay.Inbox.Timer`."
  @spec fire_timer(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, atom()} | {:error, term()}
  def fire_timer(%Relay.Scope{} = scope, recipient_id, item_id) do
    Store.in_scope(scope, fn _status ->
      fired(scope, recipient_id, item_id, Store.timer_fire(recipient_id, item_id))
    end)
  end

  defp fired(_scope, _recipient_id, _item_id, :not_found), do: :not_found

  defp fired(scope, recipient_id, item_id, {code, next_at}) do
    schedule(scope, recipient_id, item_id, next_at)
    if code == :fired, do: sync!(scope, recipient_id)
    code
  end

  # IN-18
  # IN-19
  # IN-21
  # IN-3
  @doc "The subscriber's absolute, versioned counters over its items and the announcements of its audience: `unseen`, `unread`, `total` and `version`."
  @spec counters(Relay.Scope.t(), Relay.Id.t()) :: {:ok, counters()} | {:error, term()}
  def counters(%Relay.Scope{} = scope, subscriber_id),
    do: Store.in_scope(scope, fn _status -> merged_counters(subscriber_id) end)

  defp merged_counters(subscriber_id) do
    personal = Store.counters(subscriber_id)
    extra = Announcement.counts(Store.announcements(subscriber_id), Relay.Clock.utc_now())

    %{
      unseen: personal.unseen + extra.unseen,
      unread: personal.unread + extra.unread,
      total: personal.total + extra.total,
      version: personal.version + Store.announcement_head()
    }
  end

  # IN-29
  # IN-30
  # IN-28
  # IN-3
  @doc """
  The cold sync of a subscriber: the stream position, the counters and the first page of items merged with the announcements of its audience (or the page after `:after`), read in that order so every change after the position reaches the reader again through `changes/4`. Options: `:limit` (1 to 100, default 50), `:after` (`{last_activity_at, id}` of the last item seen), `:status` (`:inbox` by default, `:unread`, `:archived`, `:snoozed` or `:all`), `:category`, `:tag`. Items are full views with their content; an announcement is listed at its publication time.
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
      ann_head = Store.announcement_head()
      counters = merged_counters(subscriber_id)
      rows = Store.list(subscriber_id, filters, opts[:after], limit + 1)
      announcements = Store.announcements(subscriber_id, content: true)
      {head, ann_head, counters, rows, announcements}
    end

    with {:ok, {head, ann_head, counters, rows, announcements}} <- Store.in_scope(scope, read) do
      now = Relay.Clock.utc_now()

      listed =
        for row <- announcements,
            Announcement.listed?(row, filters, now),
            before?(Announcement.position(row), opts[:after]),
            do: {:announcement, row}

      merged = merge(Enum.map(rows, &{:item, &1}), listed)
      {page, rest} = Enum.split(Enum.take(merged, limit + 1), limit)

      {:ok,
       %{
         items: entry_views(scope, page),
         has_more: rest != [],
         next: if(rest != [], do: entry_position(List.last(page))),
         counters: counters,
         cursor: %{epoch: head.epoch, seq: head.seq, ann: ann_head}
       }}
    end
  end

  defp merge(items, []), do: items
  defp merge([], announcements), do: announcements

  defp merge([item | items] = all_items, [announcement | announcements] = all_announcements) do
    if newer?(entry_position(item), entry_position(announcement)),
      do: [item | merge(items, all_announcements)],
      else: [announcement | merge(all_items, announcements)]
  end

  defp entry_position({:item, row}), do: {row["last_activity_at"], row["id"]}
  defp entry_position({:announcement, row}), do: Announcement.position(row)

  defp newer?({at, id}, {other_at, other_id}) do
    case DateTime.compare(at, other_at) do
      :gt -> true
      :lt -> false
      :eq -> id > other_id
    end
  end

  defp before?(_position, nil), do: true
  defp before?(position, after_position), do: newer?(after_position, position)

  defp entry_views(scope, entries) do
    now = Relay.Clock.utc_now()
    rows = for {:item, row} <- entries, do: row
    views = Map.new(Enum.zip(Enum.map(rows, & &1["id"]), views(scope, rows)))

    for entry <- entries do
      case entry do
        {:item, row} -> Map.fetch!(views, row["id"])
        {:announcement, row} -> Announcement.view(row, now)
      end
    end
  end

  # IN-5
  # IN-3
  @doc "One visible item of a subscriber, or one visible announcement of its audience (`{:announcement, id}`), as a full view; a hidden, retracted or expired one and another subscriber's item are `:not_found`."
  @spec get(Relay.Scope.t(), Relay.Id.t(), target()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def get(%Relay.Scope{} = scope, subscriber_id, {:announcement, id}) do
    case Store.in_scope(scope, fn _status -> Store.announcement(subscriber_id, id) end) do
      {:ok, nil} ->
        :not_found

      {:ok, row} ->
        now = Relay.Clock.utc_now()

        if Announcement.removed?(row, now),
          do: :not_found,
          else: {:ok, Announcement.view(row, now)}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
  # IN-3
  @doc """
  The delta sync of a subscriber: the items and announcements created, updated and removed (hidden, retracted or expired) after `cursor`, at most `limit` (1 to 500): first the changes of the subscriber's stream in stream order (its items and its own announcement states), then the announcements of its audience published or closed after the cursor's announcement sequence. Each change carries its full view (`removed` ones their state view only) and the cursor right after it; the page carries the next cursor and the merged counters. `has_more` says another page follows; `truncated` says more than 500 changes wait, so the reader should start over with a cold sync instead of paging. A `nil` cursor, another epoch or a position outside the stream is `{:resync_required, %{reason, cursor, counters}}` with the current position. `changes/4` is its realtime source form.
  """
  @spec delta(Relay.Scope.t(), Relay.Id.t(), Cursor.t() | nil, pos_integer()) ::
          {:ok, page()} | {:resync_required, map()} | {:error, term()}
  def delta(%Relay.Scope{} = scope, subscriber_id, cursor, limit \\ 500) do
    cap = Item.limits()["changes_max"]
    limit = limit |> max(1) |> min(cap)

    read = fn _status ->
      head = Store.head(subscriber_id)
      ann_head = Store.announcement_head()
      counters = merged_counters(subscriber_id)

      case position(cursor, head, ann_head) do
        :ok ->
          {:ok, delta_read(subscriber_id, head, ann_head, cursor, {limit, cap}), counters}

        {:resync, reason} ->
          {:resync, reason, %{epoch: head.epoch, seq: head.seq, ann: ann_head}, counters}
      end
    end

    case Store.in_scope(scope, read) do
      {:ok, {:ok, found, counters}} ->
        {:ok, page(scope, found, counters)}

      {:ok, {:resync, reason, position, counters}} ->
        {:resync_required, %{reason: reason, cursor: position, counters: counters}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delta_read(subscriber_id, head, ann_head, cursor, {limit, cap}) do
    since = cursor.seq
    since_ann = Map.get(cursor, :ann, 0)
    items = Store.changed(subscriber_id, head.epoch, since, limit + 1)
    states = Store.announcement_states_changed(subscriber_id, head.epoch, since, limit + 1)
    stream = Enum.take(stream_merge(items, states), limit + 1)
    waiting = Store.changed_count(subscriber_id, head.epoch, since, cap + 1) + length(states)

    {stream, records, has_more} =
      if length(stream) > limit do
        {Enum.take(stream, limit), [], true}
      else
        room = limit - length(stream)
        found = records_after(subscriber_id, since_ann, room)
        more = length(found) > room or (room == 0 and ann_head > since_ann)
        {stream, Enum.take(found, room), more}
      end

    %{
      head: head,
      ann_head: ann_head,
      since: since,
      since_ann: since_ann,
      stream: stream,
      records: records,
      has_more: has_more,
      truncated: waiting + length(records) > cap
    }
  end

  defp records_after(_subscriber_id, _since_ann, 0), do: []

  defp records_after(subscriber_id, since_ann, room),
    do: Store.announcements_changed(subscriber_id, since_ann, room + 1)

  defp stream_merge(items, []), do: Enum.map(items, &{:item, &1})
  defp stream_merge([], states), do: Enum.map(states, &{:state, &1})

  defp stream_merge([item | items] = all_items, [state | states] = all_states) do
    if item["change_seq"] < state["state_change_seq"],
      do: [{:item, item} | stream_merge(items, all_states)],
      else: [{:state, state} | stream_merge(all_items, states)]
  end

  defp position(nil, _head, _ann_head), do: {:resync, "position_out_of_range"}

  defp position(%{epoch: epoch}, %{epoch: current}, _ann_head) when epoch != current,
    do: {:resync, "epoch_changed"}

  defp position(%{seq: seq}, %{seq: head, floor: floor}, _ann_head)
       when seq > head or seq < floor,
       do: {:resync, "position_out_of_range"}

  defp position(%{ann: ann}, _head, ann_head) when ann > ann_head,
    do: {:resync, "position_out_of_range"}

  defp position(_cursor, _head, _ann_head), do: :ok

  defp page(scope, found, counters) do
    now = Relay.Clock.utc_now()
    %{head: head, since_ann: since_ann, stream: stream, records: records} = found
    item_rows = for {:item, row} <- stream, not Item.removed?(row, now), do: row
    views = Map.new(Enum.zip(Enum.map(item_rows, & &1["id"]), views(scope, item_rows)))

    stream_changes =
      for entry <- stream,
          do: stream_change(entry, {head, found.since}, views, now, since_ann)

    stream_seq = Enum.reduce(stream_changes, head.seq, &max(&1.seq, &2))

    seq =
      if found.has_more and records == [],
        do: List.last(stream_changes).seq,
        else: stream_seq

    record_changes = for row <- records, do: record_change(row, head.epoch, seq, now)

    ann =
      cond do
        records == [] and found.has_more -> since_ann
        found.has_more -> List.last(records)["change_seq"]
        true -> found.ann_head
      end

    %{
      changes: stream_changes ++ record_changes,
      cursor: %{epoch: head.epoch, seq: seq, ann: ann},
      counters: counters,
      has_more: found.has_more,
      truncated: found.truncated
    }
  end

  defp stream_change({:item, row}, {head, since}, views, now, since_ann) do
    removed? = Item.removed?(row, now)

    %{
      type: change_type(row, removed?, head.epoch, since),
      item_id: row["id"],
      ref: Relay.ExternalId.encode("inb", row["id"]),
      seq: row["change_seq"],
      state_version: row["state_version"],
      item: if(removed?, do: Item.state_view(row, now), else: Map.fetch!(views, row["id"])),
      position: %{epoch: head.epoch, seq: row["change_seq"], ann: since_ann}
    }
  end

  defp stream_change({:state, row}, {head, _since}, _views, now, since_ann) do
    removed? = Announcement.removed?(row, now)

    %{
      type: if(removed?, do: :removed, else: :updated),
      item_id: row["id"],
      ref: Relay.ExternalId.encode("ann", row["id"]),
      seq: row["state_change_seq"],
      state_version: row["state_version"],
      item:
        if(removed?, do: Announcement.state_view(row, now), else: Announcement.view(row, now)),
      position: %{epoch: head.epoch, seq: row["state_change_seq"], ann: since_ann}
    }
  end

  defp record_change(row, epoch, seq, now) do
    removed? = Announcement.removed?(row, now)

    %{
      type: if(removed?, do: :removed, else: :created),
      item_id: row["id"],
      ref: Relay.ExternalId.encode("ann", row["id"]),
      seq: seq,
      state_version: row["state_version"],
      item:
        if(removed?, do: Announcement.state_view(row, now), else: Announcement.view(row, now)),
      position: %{epoch: epoch, seq: seq, ann: row["change_seq"]}
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
    read = fn _status -> {Store.head(subscriber_id), Store.announcement_head()} end

    case Store.in_scope(scope, read) do
      {:ok, {head, ann}} -> {:ok, Cursor.encode(%{epoch: head.epoch, seq: head.seq, ann: ann})}
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

  # IN-50
  # IN-14
  # X-17
  # DS-7
  # WF-27
  @doc """
  Marks all read inside the caller's transaction (IN-50): the subscriber's unread items of the inbox tab, of every category or of `category`, whose last activity is not after the request's server time are read in one set update, each with a new `state_version` and its engagement evidence; the read mark of the scope reads the earlier announcements of the audience; the counters are written again and one `inbox.items_bulk_updated` and one `inbox.counters_changed` are published. Nothing is archived. The read cancels the pending digest windows of the read items' notifications. Returns how many items changed, the merged counters and the cut-off.
  """
  @spec read_all(Relay.Scope.t(), Relay.Id.t(), String.t() | nil) :: %{
          updated: non_neg_integer(),
          counters: counters(),
          cut_off: DateTime.t()
        }
  def read_all(%Relay.Scope{} = scope, subscriber_id, category) do
    result = Store.read_all(subscriber_id, category)
    digest_read!(scope, subscriber_id, result.notification_ids)

    %{
      updated: result.updated,
      counters: merged_counters(subscriber_id),
      cut_off: result.cut_off
    }
  end

  # IN-14
  @doc """
  Starts an asynchronous bulk action inside the caller's transaction: `attrs` carries `:action` (`read`, `archive` or `hide`), `:status` (the list filter, as in `snapshot/3`), `:category` and `:tag`. The operation covers the subscriber's matching items created before the request; its first chunk job is queued in the same transaction. Returns the operation's identifier.
  """
  @spec start_bulk(Relay.Scope.t(), Relay.Id.t(), map()) :: Relay.Id.t()
  def start_bulk(%Relay.Scope{} = scope, subscriber_id, attrs) do
    id = Relay.Id.generate()
    _cut_off = Store.bulk_start(id, subscriber_id, attrs)
    bulk_job!(scope, id)
    id
  end

  # IN-14
  @doc "A bulk operation of the subscriber with its progress, or `:not_found`."
  @spec bulk(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def bulk(%Relay.Scope{} = scope, subscriber_id, operation_id) do
    case Store.in_scope(scope, fn _status -> Store.bulk(subscriber_id, operation_id) end) do
      {:ok, nil} -> :not_found
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  # IN-14
  # IN-35
  # WF-27
  # WF-43
  @doc "Applies the next chunk of a bulk operation in its own transaction and queues the next chunk in the same one while more remain; a chunk that changed items queues a sync signal to the subscriber's devices, and read items cancel their pending digest windows. Used by `Relay.Inbox.BulkJob`."
  @spec run_bulk(Relay.Scope.t(), Relay.Id.t()) :: {:ok, atom()} | {:error, term()}
  def run_bulk(%Relay.Scope{} = scope, operation_id) do
    Store.in_scope(scope, fn _status ->
      bulk_ran(scope, operation_id, Store.bulk_chunk(operation_id, @bulk_chunk))
    end)
  end

  defp bulk_ran(_scope, _operation_id, :not_found), do: :not_found

  defp bulk_ran(scope, operation_id, {code, chunk}) do
    if code == :chunk, do: bulk_job!(scope, operation_id)
    if chunk.changed > 0, do: bulk_changed(scope, chunk)
    code
  end

  defp bulk_changed(scope, chunk) do
    digest_read!(scope, chunk.recipient_id, chunk.notification_ids)
    sync!(scope, chunk.recipient_id)
  end

  defp bulk_job!(scope, operation_id) do
    args =
      scope
      |> Relay.Scope.to_job_args()
      |> Map.put("operation_id", Relay.Id.to_string(operation_id))

    Store.insert_job!(BulkJob.new(args))
  end

  # IN-21
  # IN-35
  @doc "Reconciles the subscriber's counters with its items at once, inside the caller's transaction, after its client reported them inconsistent: drifted counters are rewritten with a new version and published, and the devices get a sync signal. Emits `[:relay, :inbox, :inconsistency_report]` with the result. Returns `:consistent` or `:repaired` and the merged counters."
  @spec reconcile(Relay.Scope.t(), Relay.Id.t()) :: {:consistent | :repaired, counters()}
  def reconcile(%Relay.Scope{} = scope, subscriber_id) do
    {result, _version} = Store.reconcile(subscriber_id)
    if result == :repaired, do: sync!(scope, subscriber_id)

    :telemetry.execute([:relay, :inbox, :inconsistency_report], %{count: 1}, %{result: result})

    if result == :repaired,
      do: :telemetry.execute([:relay, :inbox, :counter_drift], %{count: 1}, %{source: :report})

    {result, merged_counters(subscriber_id)}
  end

  # IN-18
  # OP-42
  @doc "Reconciles, in its own transaction, the counters of at most `limit` recipients of a scope whose counters or items changed since `since`, after `after_id` in identifier order; drifted counters are fixed and counted in `[:relay, :inbox, :counter_drift]`. Returns how many were checked and repaired and the last recipient checked."
  @spec reconcile_changed(Relay.Scope.t(), DateTime.t(), Relay.Id.t() | nil, pos_integer()) ::
          {:ok, reconciled()} | {:error, term()}
  def reconcile_changed(%Relay.Scope{} = scope, since, after_id, limit) do
    read = fn _status -> Store.reconcile_changed(since, after_id, limit) end

    with {:ok, result} <- Store.in_scope(scope, read) do
      if result.repaired > 0,
        do:
          :telemetry.execute([:relay, :inbox, :counter_drift], %{count: result.repaired}, %{
            source: :nightly
          })

      {:ok, result}
    end
  end

  # IN-44
  # OP-22
  # IN-35
  @doc "Ends, in its own transaction, the retention of at most `limit` due items of a scope under the tenant's `inbox.retention` setting: an item in the inbox past its active period, or archived past its archive period, is soft deleted (hidden with reason `retention`) and its content shredded; the row stays. The recipients reached get a sync signal. Returns how many items were retired."
  @spec retire_due(Relay.Scope.t(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def retire_due(%Relay.Scope{} = scope, limit) do
    Store.in_scope(scope, fn _status ->
      retention = retention()
      result = Store.retire_due(retention["active_days"], retention["archive_days"], limit)
      Enum.each(result.recipient_ids, &sync!(scope, &1))
      result.retired
    end)
  end

  # IN-44
  # OP-22
  @doc "The retention defaults of the contract (`x-relay-limits` `inbox.retention`): the visible items, the active days and the archive days."
  @spec retention_defaults() :: map()
  def retention_defaults, do: @retention

  defp retention, do: Map.merge(@retention, Store.retention_setting() || %{})

  # IN-3
  # C-70
  # API-35
  # IN-17
  @doc """
  Publishes an announcement inside the caller's transaction: one record for its audience (`:audience` `tenant`, `subtenant` with `:subtenant_id`, or `topic` with `:topic_key`), with `:category`, `:tags`, `:severity`, the rendered `:content`, `:locale`, `:dir` and an optional `:expires_at`, whose timer is queued in the same transaction. No row is written per recipient. Audited as `inbox_announcement.published`.
  """
  @spec create_announcement(Relay.Scope.t(), map(), binary(), Relay.Actor.t()) ::
          {:created, Relay.Id.t()} | :tenant_inactive | :subtenant_not_found | :topic_not_found
  def create_announcement(%Relay.Scope{} = scope, attrs, digest, actor) do
    id = Relay.Id.generate()

    case Store.announcement_create(Map.put(attrs, :id, id), digest, actor) do
      :created ->
        announcement_timer!(scope, id, attrs[:expires_at])
        {:created, id}

      other ->
        other
    end
  end

  # IN-3
  # IN-16
  @doc "Retracts an announcement inside the caller's transaction: it leaves every list and counter of its audience. Audited as `inbox_announcement.retracted`."
  @spec retract_announcement(Relay.Id.t(), binary(), Relay.Actor.t()) ::
          :retracted | :already_closed | :not_found
  def retract_announcement(announcement_id, digest, actor),
    do: Store.announcement_retract(announcement_id, digest, actor)

  # IN-3
  @doc "An announcement record of the scope as the server API reads it, inside the caller's transaction, or `nil`."
  @spec announcement_record(Relay.Id.t()) :: map() | nil
  defdelegate announcement_record(announcement_id), to: Store

  # IN-3
  @doc "An announcement record of the scope as the server API reads it, in its own transaction, or `nil`."
  @spec read_announcement(Relay.Scope.t(), Relay.Id.t()) :: {:ok, map() | nil} | {:error, term()}
  def read_announcement(%Relay.Scope{} = scope, announcement_id),
    do: Store.in_scope(scope, fn _status -> Store.announcement_record(announcement_id) end)

  # IN-17
  @doc "Ends a due announcement in its own transaction; used by `Relay.Inbox.AnnouncementTimer`."
  @spec expire_announcement(Relay.Scope.t(), Relay.Id.t()) :: {:ok, atom()} | {:error, term()}
  def expire_announcement(%Relay.Scope{} = scope, announcement_id),
    do: Store.in_scope(scope, fn _status -> Store.announcement_expire(announcement_id) end)

  defp announcement_timer!(_scope, _id, nil), do: :ok

  defp announcement_timer!(scope, id, %DateTime{} = at) do
    args =
      scope
      |> Relay.Scope.to_job_args()
      |> Map.put("announcement_id", Relay.Id.to_string(id))

    Store.insert_job!(AnnouncementTimer.new(args, scheduled_at: Relay.Clock.wall_time(scope, at)))
  end

  # IN-35
  defp sync!(scope, recipient_id) do
    counters = merged_counters(recipient_id)

    {:ok, _job} = Relay.Devices.sync(scope, recipient_id, counters)
    :ok
  end

  # WF-27
  defp digest_read!(_scope, _recipient_id, []), do: :ok

  defp digest_read!(scope, recipient_id, notification_ids) do
    for id <- Enum.uniq(notification_ids),
        do: _ = Relay.Workflow.digest_read_in_scope(scope, recipient_id, id)

    :ok
  end

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
