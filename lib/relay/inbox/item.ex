defmodule Relay.Inbox.Item do
  @moduledoc """
  The inbox item model, pure (IN-4, IN-9 … IN-11, IN-49). An item is a topic with activities: its rendered content (title, body, avatar, action buttons, data rows, link, locale and direction), its category, tags, severity and group key, its activity and actor counts and last activity time, and its state.

  The state is read from two monotone server stamps per reversible axis (`read_at` / `unread_marked_at`, `archived_at` / `unarchived_at`), the later one winning (IN-11). `seen` and `read` are separate axes (IN-10) and both are measured against the last activity, so a cumulative update makes the item unseen and unread again. `hidden` is terminal for the user; an expired item leaves the list and the counters and its row stays (IN-17).

  `check/2` applies the published field limits of `x-relay-limits` `inbox` (IN-49): a breach is `inbox_item_too_large`, an action URL that is not `https` is `schema_violation`; both fail the delivery without retry (TP-41). `event_item/1` is the `inbox.item_created` body: the full item when its JSON is at most the realtime threshold, else the thin summary (IN-27).
  """

  @limits Relay.Limits.fetch!(["inbox"])

  @type content :: %{String.t() => term()}

  # IN-49
  @doc "The published inbox limits."
  @spec limits() :: map()
  def limits, do: @limits

  # IN-49
  # TP-41
  @doc "Checks rendered content and the item's tags and group key against the published limits."
  @spec check(content(), map()) ::
          :ok | {:error, :inbox_item_too_large | :schema_violation, map()}
  def check(content, meta) do
    checks =
      [
        bytes("/title", content["title"], "title_max_bytes"),
        bytes("/body", content["body"], "body_max_bytes"),
        bytes("/avatar_url", content["avatar_url"], "avatar_url_max_bytes"),
        bytes("/url", content["url"], "action_url_max_bytes"),
        count("/actions", content["actions"], "actions_max"),
        count("/data", content["data"], "data_rows_max"),
        count("/tags", meta.tags, "tags_max"),
        bytes("/group_key", meta.group_key, "group_key_max_bytes")
      ] ++
        actions(content["actions"] || []) ++
        rows(content["data"] || []) ++
        Enum.map(meta.tags, &bytes("/tags", &1, "tag_max_bytes"))

    case Enum.find(checks, &(&1 != :ok)) do
      nil -> whole(content, meta)
      failure -> failure
    end
  end

  defp actions(actions) do
    actions
    |> Enum.with_index()
    |> Enum.flat_map(fn {action, index} ->
      path = "/actions/#{index}"

      [
        bytes(path <> "/label", action["label"], "action_label_max_bytes"),
        bytes(path <> "/url", action["url"], "action_url_max_bytes"),
        https(path <> "/url", action["url"])
      ]
    end)
  end

  defp rows(rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} ->
      path = "/data/#{index}"

      [
        bytes(path <> "/key", row["key"], "data_key_max_bytes"),
        bytes(path <> "/value", row["value"], "data_value_max_bytes")
      ]
    end)
  end

  defp whole(content, meta) do
    size = json_bytes(%{"content" => content, "tags" => meta.tags, "group_key" => meta.group_key})
    limit = @limits["item_max_bytes"]

    if size <= limit,
      do: :ok,
      else: {:error, :inbox_item_too_large, detail("/", limit, size)}
  end

  defp bytes(_pointer, nil, _limit), do: :ok

  defp bytes(pointer, value, limit) when is_binary(value) do
    max = @limits[limit]

    if byte_size(value) <= max,
      do: :ok,
      else: {:error, :inbox_item_too_large, detail(pointer, max, byte_size(value))}
  end

  defp bytes(pointer, _value, _limit),
    do: {:error, :schema_violation, %{"cause" => "invalid_field", "field" => pointer}}

  defp count(_pointer, nil, _limit), do: :ok

  defp count(pointer, list, limit) when is_list(list) do
    max = @limits[limit]

    if length(list) <= max,
      do: :ok,
      else: {:error, :inbox_item_too_large, detail(pointer, max, length(list))}
  end

  defp https(_pointer, nil), do: :ok

  defp https(pointer, url) do
    if String.starts_with?(String.downcase(url), "https://"),
      do: :ok,
      else: {:error, :schema_violation, %{"cause" => "action_url_scheme", "field" => pointer}}
  end

  defp detail(pointer, limit, actual),
    do: %{"field" => pointer, "limit" => limit, "actual" => actual}

  @doc "The byte size of a value's JSON encoding."
  @spec json_bytes(term()) :: non_neg_integer()
  def json_bytes(value), do: value |> Jason.encode_to_iodata!() |> IO.iodata_length()

  # IN-10
  # IN-11
  # IN-17
  @doc "The effective state of an item row at `now`."
  @spec state(map(), DateTime.t()) :: map()
  def state(row, now) do
    activity = row["last_activity_at"]

    %{
      seen: current?(row["seen_at"], activity),
      read:
        current?(row["read_at"], activity) and later?(row["read_at"], row["unread_marked_at"]),
      archived: later?(row["archived_at"], row["unarchived_at"]),
      hidden: row["hidden_at"] != nil,
      snoozed: row["snoozed_until"] != nil and DateTime.compare(row["snoozed_until"], now) == :gt,
      expired:
        row["expired_at"] != nil or
          (row["expires_at"] != nil and DateTime.compare(row["expires_at"], now) != :gt)
    }
  end

  defp current?(nil, _activity), do: false
  defp current?(stamp, activity), do: DateTime.compare(stamp, activity) != :lt

  defp later?(nil, _other), do: false
  defp later?(_stamp, nil), do: true
  defp later?(stamp, other), do: DateTime.compare(stamp, other) == :gt

  # IN-29
  @doc "Whether an item is out of every list at `now`: hidden or expired."
  @spec removed?(map(), DateTime.t()) :: boolean()
  def removed?(row, now) do
    state = state(row, now)
    state.hidden or state.expired
  end

  # IN-5
  # IN-12
  @doc "The state view of an item: its identifier, `state_version` and state fields, without content."
  @spec state_view(map(), DateTime.t()) :: map()
  def state_view(row, now) do
    state = state(row, now)

    %{
      "id" => Relay.ExternalId.encode("inb", row["id"]),
      "state_version" => row["state_version"],
      "seen" => state.seen,
      "read" => state.read,
      "archived" => state.archived,
      "hidden" => state.hidden,
      "expired" => state.expired,
      "snoozed_until" => if(state.snoozed, do: row["snoozed_until"]),
      "seen_at" => row["seen_at"],
      "read_at" => if(state.read, do: row["read_at"]),
      "archived_at" => if(state.archived, do: row["archived_at"])
    }
  end

  # IN-4
  # IN-5
  @doc "The full view of an item with its decrypted content (`nil` when the content cannot be read, as after an erasure)."
  @spec view(map(), content() | nil, DateTime.t()) :: map()
  def view(row, content, now) do
    content = content || %{}

    row
    |> state_view(now)
    |> Map.merge(%{
      "object" => "inbox_item",
      "kind" => "personal",
      "created_at" => row["created_at"],
      "last_activity_at" => row["last_activity_at"],
      "category" => row["category"],
      "tags" => row["tags"] || [],
      "severity" => row["severity"],
      "group_key" => row["group_key"],
      "title" => content["title"],
      "body" => content["body"],
      "avatar_url" => content["avatar_url"],
      "url" => content["url"],
      "actions" => content["actions"] || [],
      "data" => content["data"] || [],
      "locale" => row["locale"],
      "dir" => row["dir"],
      "activity_count" => row["activity_count"],
      "actor_count" => row["actor_count"],
      "expires_at" => row["expires_at"]
    })
  end

  # IN-27
  # IN-49
  @doc "The body of `inbox.item_created`: the full item when its JSON is within the realtime threshold, else the thin summary (identifier, `state_version`, `created_at`, category and severity) and `thin: true`."
  @spec event_item(map()) :: map()
  def event_item(view) do
    if json_bytes(view) <= @limits["realtime_item_max_bytes"] do
      %{"item" => view, "state_version" => view["state_version"]}
    else
      thin = Map.take(view, ["id", "state_version", "created_at", "category", "severity"])
      %{"item" => thin, "state_version" => view["state_version"], "thin" => true}
    end
  end
end
