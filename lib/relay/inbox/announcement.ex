defmodule Relay.Inbox.Announcement do
  @moduledoc """
  The announcement model, pure (IN-3, C-70, IN-50). An announcement is one record for a whole audience (the tenant's environment, a sub-tenant, or the subscribers of a topic), merged into each recipient's personal list at read time; no row is written per recipient until the recipient acts on it.

  A row merges the record with the recipient's own state (`seen_at`, `read_at`, `unread_marked_at`, `archived_at`, `unarchived_at`, `hidden_at`, written only by the recipient's intents) and with `mark`, the latest read mark of "mark all read" that covers the announcement's category and is not older than its publication. The read stamp is the later of the recipient's own read and the mark, so a read mark reads every earlier announcement of its scope without a row per recipient; an unread after it wins as for an item (IN-11). Seen follows read (IN-9). An announcement never snoozes.

  The counters of the merged view count an announcement like an item: in the inbox tab while active, not expired, not hidden and not archived (IN-18).
  """

  @statuses [:inbox, :unread, :archived, :snoozed, :all]

  # IN-50
  # IN-10
  # IN-11
  @doc "The effective state of an announcement row at `now`."
  @spec state(map(), DateTime.t()) :: map()
  def state(row, now) do
    read_at = latest(row["read_at"], row["mark"])
    read = read_at != nil and later?(read_at, row["unread_marked_at"])

    %{
      seen: row["seen_at"] != nil or read_at != nil,
      seen_at: row["seen_at"] || read_at,
      read: read,
      read_at: if(read, do: read_at),
      archived: row["archived_at"] != nil and later?(row["archived_at"], row["unarchived_at"]),
      hidden: row["hidden_at"] != nil or row["state"] == "retracted",
      expired:
        row["state"] == "expired" or
          (row["expires_at"] != nil and DateTime.compare(row["expires_at"], now) != :gt)
    }
  end

  defp latest(nil, other), do: other
  defp latest(stamp, nil), do: stamp
  defp latest(stamp, other), do: if(DateTime.compare(stamp, other) == :lt, do: other, else: stamp)

  defp later?(_stamp, nil), do: true
  defp later?(stamp, other), do: DateTime.compare(stamp, other) == :gt

  # IN-29
  @doc "Whether an announcement is out of every list at `now`: retracted, expired or hidden."
  @spec removed?(map(), DateTime.t()) :: boolean()
  def removed?(row, now) do
    state = state(row, now)
    state.hidden or state.expired
  end

  # IN-7
  @doc "Whether an announcement row is in a list of `status`, `category` and `tag` at `now`."
  @spec listed?(map(), map(), DateTime.t()) :: boolean()
  def listed?(row, filters, now) do
    state = state(row, now)
    status = Map.get(filters, :status, :inbox)
    true = status in @statuses

    not state.hidden and not state.expired and status?(status, state) and
      (filters[:category] == nil or filters[:category] == row["category"]) and
      (filters[:tag] == nil or filters[:tag] in (row["tags"] || []))
  end

  defp status?(:inbox, state), do: not state.archived
  defp status?(:unread, state), do: not state.archived and not state.read
  defp status?(:archived, state), do: state.archived
  defp status?(:snoozed, _state), do: false
  defp status?(:all, _state), do: true

  # IN-18
  # IN-3
  @doc "What a set of announcement rows adds to the counters at `now`."
  @spec counts([map()], DateTime.t()) :: %{
          unseen: non_neg_integer(),
          unread: non_neg_integer(),
          total: non_neg_integer()
        }
  def counts(rows, now) do
    Enum.reduce(rows, %{unseen: 0, unread: 0, total: 0}, fn row, acc ->
      state = state(row, now)

      if state.hidden or state.expired or state.archived do
        acc
      else
        %{
          unseen: acc.unseen + if(state.seen, do: 0, else: 1),
          unread: acc.unread + if(state.read, do: 0, else: 1),
          total: acc.total + 1
        }
      end
    end)
  end

  # IN-5
  # IN-12
  @doc "The state view of an announcement, the shape of an item's state view."
  @spec state_view(map(), DateTime.t()) :: map()
  def state_view(row, now) do
    state = state(row, now)

    %{
      "id" => Relay.ExternalId.encode("ann", row["id"]),
      "state_version" => row["state_version"],
      "seen" => state.seen,
      "read" => state.read,
      "archived" => state.archived,
      "hidden" => state.hidden,
      "expired" => state.expired,
      "snoozed_until" => nil,
      "seen_at" => state.seen_at,
      "read_at" => state.read_at,
      "archived_at" => if(state.archived, do: row["archived_at"])
    }
  end

  # IN-3
  # IN-4
  @doc "The full view of an announcement, the shape of an inbox item with `kind: announcement`."
  @spec view(map(), DateTime.t()) :: map()
  def view(row, now) do
    content = row["content"] || %{}

    row
    |> state_view(now)
    |> Map.merge(%{
      "object" => "inbox_item",
      "kind" => "announcement",
      "created_at" => row["published_at"],
      "last_activity_at" => row["published_at"],
      "category" => row["category"],
      "tags" => row["tags"] || [],
      "severity" => row["severity"],
      "group_key" => nil,
      "title" => content["title"],
      "body" => content["body"],
      "avatar_url" => content["avatar_url"],
      "url" => content["url"],
      "actions" => content["actions"] || [],
      "data" => content["data"] || [],
      "locale" => row["locale"],
      "dir" => row["dir"],
      "activity_count" => 1,
      "actor_count" => 0,
      "expires_at" => row["expires_at"]
    })
  end

  # IN-30
  @doc "The keyset position of an announcement in the merged list."
  @spec position(map()) :: {DateTime.t(), Relay.Id.t()}
  def position(row), do: {row["published_at"], row["id"]}
end
