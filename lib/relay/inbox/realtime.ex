defmodule Relay.Inbox.Realtime do
  @moduledoc """
  The realtime messages of the human inbox stream (IN-26, IN-27), built from a delta page of `Relay.Inbox.changes/4`. Every message is the one envelope `{t, v, ts, d}` and carries the recipient's absolute, versioned `counters` (IN-19); a client drops a message whose `state_version` or `counters.version` is not newer than its own, which also absorbs duplicates and replays.

  * `inbox.item_created`: the full item and its `state_version`, or the thin summary with `thin: true` when the item's JSON is above the realtime threshold (IN-49); the client then reads the item.
  * `inbox.item_updated`: the item identifier, its `state_version` and the changed fields: the state fields, and the content too when the item is within the threshold. An item that left every list (hidden, retracted, expired) carries `hidden` or `expired`.
  * `inbox.counters_changed`: `unseen`, `unread`, `total` and `version`.
  * `stream.resync_required`: the reader must start over with a cold sync.

  Each message is paired with the stream cursor of its change, which a transport uses as its event identifier.
  """

  alias Relay.Inbox.Cursor
  alias Relay.Inbox.Item

  @version 1
  @state_fields ~w(seen read archived hidden expired snoozed_until seen_at read_at archived_at)

  @type message :: %{String.t() => term()}

  # IN-26
  @doc "Wraps a body in the envelope with the recipient's counters."
  @spec envelope(String.t(), map(), map(), DateTime.t()) :: message()
  def envelope(type, body, counters, %DateTime{} = ts) do
    %{"t" => type, "v" => @version, "ts" => ts, "d" => body, "counters" => counters(counters)}
  end

  # IN-19
  @doc "The counters as a realtime message carries them."
  @spec counters(map()) :: map()
  def counters(%{unseen: unseen, unread: unread, total: total, version: version}),
    do: %{"unseen" => unseen, "unread" => unread, "total" => total, "version" => version}

  # IN-26
  # IN-27
  @doc "The messages of a delta page in stream order, each with the cursor of its change, followed by one `inbox.counters_changed` when the page has changes."
  @spec messages(map(), DateTime.t()) :: [{String.t(), message()}]
  def messages(%{changes: changes, counters: counters, cursor: cursor}, ts) do
    items =
      for change <- changes do
        fallback = %{epoch: cursor.epoch, seq: change.seq}
        position = Cursor.encode(Map.get(change, :position, fallback))
        {position, envelope(type(change), body(change), counters, ts)}
      end

    case items do
      [] ->
        []

      _some ->
        body = counters(counters)
        items ++ [{Cursor.encode(cursor), envelope("inbox.counters_changed", body, counters, ts)}]
    end
  end

  # IN-22
  @doc "The message that tells a reader to start over, with the reason (`epoch_changed`, `position_out_of_range`, `truncated`)."
  @spec resync(String.t(), map(), DateTime.t()) :: message()
  def resync(reason, counters, ts),
    do: envelope("stream.resync_required", %{"reason" => reason}, counters, ts)

  defp type(%{type: :created}), do: "inbox.item_created"
  defp type(_change), do: "inbox.item_updated"

  defp body(%{type: :created, item: item}), do: Item.event_item(item)

  defp body(%{item: item}) do
    fields =
      if Item.json_bytes(item) <= Item.limits()["realtime_item_max_bytes"],
        do: Map.drop(item, ["id", "object", "state_version"]),
        else: Map.take(item, @state_fields)

    %{"item_id" => item["id"], "state_version" => item["state_version"], "changes" => fields}
  end
end
