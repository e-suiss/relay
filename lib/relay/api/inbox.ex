defmodule Relay.Api.Inbox do
  @moduledoc """
  The inbox operations of the client family (IN-29 … IN-31, IN-43): the subscriber lists its items (keyset pages with a signed cursor bound to the tenant, the subscriber and the endpoint; the first page carries the counters and the stream cursor, so it is the cold sync), reads one item, reads its counters, reads the changes after a stream cursor (at most 500, `truncated` beyond, `resync_required` when the cursor's epoch or position no longer holds) and sends state intents. Announcements of the subscriber's audience are merged into every read and take the same intents except snooze (IN-3). The subscriber marks all read (IN-50), starts and follows asynchronous bulk actions (IN-14) and reports counters it finds inconsistent (IN-21). The cold sync list, the counters and the delta are limited per recipient and per tenant and environment (IN-52). The subscriber always comes from the token; the tenant identifier never appears in a response.
  """

  alias Relay.Api.Cursor
  alias Relay.Api.Pagination
  alias Relay.Api.RateLimit

  @statuses %{
    "inbox" => :inbox,
    "unread" => :unread,
    "archived" => :archived,
    "snoozed" => :snoozed,
    "all" => :all
  }
  @ops ~w(seen read unread archive unarchive hide snooze unsnooze click)
  @bulk_actions ~w(read archive hide)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # IN-29
  # IN-30
  # IN-7
  @doc "A page of the subscriber's items; the first page also carries the counters and the stream cursor."
  @spec list(Relay.Scope.t(), Relay.Id.t(), map(), String.t()) :: answer()
  def list(scope, subscriber_id, query, endpoint) do
    with :ok <- RateLimit.inbox_snapshot(scope, subscriber_id),
         {:ok, page} <- Pagination.params(query, scope, subscriber_id, endpoint),
         {:ok, filters} <- filters(query),
         {:ok, after_position} <- position(page.cursor),
         {:ok, snapshot} <- snapshot(scope, subscriber_id, page.limit, filters, after_position),
         {:ok, next} <- next(scope, subscriber_id, endpoint, snapshot.next) do
      body =
        snapshot.items
        |> Pagination.envelope(snapshot.has_more, next, nil)
        |> first_page(page.cursor, snapshot)

      {:ok, {200, [], body}}
    end
  end

  defp snapshot(scope, subscriber_id, limit, filters, after_position) do
    opts = [limit: limit, after: after_position] ++ filters

    case Relay.Inbox.snapshot(scope, subscriber_id, opts) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp first_page(body, nil, snapshot) do
    body
    |> Map.put("counters", counters_view(snapshot.counters))
    |> Map.put("cursor", Relay.Inbox.encode_cursor(snapshot.cursor))
  end

  defp first_page(body, _cursor, _snapshot), do: body

  defp filters(query) do
    status = Map.get(query, "status", "inbox")

    checks = [
      {Map.has_key?(@statuses, status), "/status", "inbox, unread, archived, snoozed or all"},
      {text?(query["category"], 128), "/category", "at most 128 characters"},
      {text?(query["tag"], 64), "/tag", "at most 64 characters"}
    ]

    case for({false, pointer, detail} <- checks, do: error(pointer, "invalid_format", detail)) do
      [] ->
        {:ok, [status: @statuses[status], category: query["category"], tag: query["tag"]]}

      errors ->
        {:error, failed(errors)}
    end
  end

  defp text?(nil, _max), do: true
  defp text?(value, max), do: is_binary(value) and value != "" and String.length(value) <= max

  defp position(nil), do: {:ok, nil}

  defp position(%{direction: :after, sort_ts_us: us, id: id}),
    do: {:ok, {DateTime.from_unix!(us, :microsecond), id}}

  defp position(%{direction: :before}),
    do: {:error, failed([error("/ending_before", "not_allowed", "use starting_after")])}

  defp next(_scope, _subscriber_id, _endpoint, nil), do: {:ok, nil}

  defp next(scope, subscriber_id, endpoint, {at, id}) do
    position = %{sort_ts_us: DateTime.to_unix(at, :microsecond), id: id}
    Cursor.encode(scope, subscriber_id, endpoint, position, :after)
  end

  # IN-5
  # IN-3
  @doc "One visible item of the subscriber, or one visible announcement of its audience."
  @spec get(Relay.Scope.t(), Relay.Id.t(), Relay.Inbox.target()) :: answer()
  def get(scope, subscriber_id, item_id) do
    case Relay.Inbox.get(scope, subscriber_id, item_id) do
      {:ok, item} -> {:ok, {200, [], item}}
      :not_found -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # IN-18
  # IN-19
  # IN-21
  @doc "The subscriber's counters."
  @spec counters(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def counters(scope, subscriber_id) do
    with :ok <- RateLimit.inbox_snapshot(scope, subscriber_id) do
      case Relay.Inbox.counters(scope, subscriber_id) do
        {:ok, counters} -> {:ok, {200, [], counters_view(counters)}}
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  # IN-22
  # IN-29
  @doc "The changes after the stream cursor `since`."
  @spec changes(Relay.Scope.t(), Relay.Id.t(), map()) :: answer()
  def changes(scope, subscriber_id, query) do
    with {:ok, cursor} <- since(query["since"]),
         {:ok, limit} <- limit(query["limit"]),
         :ok <- RateLimit.inbox_snapshot(scope, subscriber_id) do
      case Relay.Inbox.delta(scope, subscriber_id, cursor, limit) do
        {:ok, page} -> {:ok, {200, [], changes_view(page)}}
        {:resync_required, info} -> {:ok, {200, [], resync_view(info)}}
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  defp since(text) when is_binary(text) do
    case Relay.Inbox.decode_cursor(text) do
      {:ok, cursor} -> {:ok, cursor}
      :error -> {:error, failed([error("/since", "invalid_format", "a cursor from Relay")])}
    end
  end

  defp since(_missing), do: {:error, failed([error("/since", "required", "send since")])}

  defp limit(nil), do: {:ok, 500}

  defp limit(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..500 -> {:ok, n}
      _invalid -> {:error, failed([error("/limit", "invalid_format", "an integer, 1 to 500")])}
    end
  end

  defp changes_view(page) do
    %{
      "object" => "inbox_changes",
      "changes" => Enum.map(page.changes, &change_view/1),
      "cursor" => Relay.Inbox.encode_cursor(page.cursor),
      "has_more" => page.has_more,
      "truncated" => page.truncated,
      "resync_required" => false,
      "counters" => counters_view(page.counters)
    }
  end

  defp change_view(change) do
    %{
      "type" => Atom.to_string(change.type),
      "item_id" => change.ref,
      "state_version" => change.state_version,
      "cursor" => Relay.Inbox.encode_cursor(change.position),
      "item" => change.item
    }
  end

  defp resync_view(info) do
    %{
      "object" => "inbox_changes",
      "changes" => [],
      "cursor" => Relay.Inbox.encode_cursor(info.cursor),
      "has_more" => false,
      "truncated" => false,
      "resync_required" => true,
      "resync_reason" => info.reason,
      "counters" => counters_view(info.counters)
    }
  end

  # IN-12
  # IN-13
  # IN-31
  @doc "Reads a state intent request; anything else is `validation_failed`."
  @spec prepare_intent(map()) :: {:ok, Relay.Inbox.intent()} | {:error, Relay.Error.t()}
  def prepare_intent(body) do
    op = body["op"]
    base = body["base_state_version"]

    with :ok <- op(op),
         {:ok, until} <- snooze_until(op, body["snooze_until"]) do
      {:ok, %{op: op, base_state_version: base, snooze_until: until}}
    end
  end

  defp op(op) when op in @ops, do: :ok
  defp op(_op), do: {:error, failed([error("/op", "unsupported_value", Enum.join(@ops, ", "))])}

  defp snooze_until("snooze", text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      _invalid -> {:error, failed([error("/snooze_until", "invalid_format", "RFC 3339")])}
    end
  end

  defp snooze_until("snooze", _missing),
    do: {:error, failed([error("/snooze_until", "required", "snooze needs snooze_until")])}

  defp snooze_until(_op, nil), do: {:ok, nil}

  defp snooze_until(_op, _value),
    do: {:error, failed([error("/snooze_until", "not_allowed", "only snooze takes it")])}

  # IN-12
  # IN-13
  # INV-7
  @doc "Applies a prepared state intent inside the request's transaction; a reverse intent on a stale `base_state_version` is `409 inbox_item_conflict` with the current state."
  @spec intent(
          Relay.Scope.t(),
          Relay.Id.t(),
          Relay.Inbox.target(),
          Relay.Inbox.intent(),
          map()
        ) ::
          answer()
  def intent(_scope, _subscriber_id, {:announcement, _id}, %{op: op}, _body)
      when op in ["snooze", "unsnooze"],
      do: {:error, failed([error("/op", "not_allowed", "an announcement does not snooze")])}

  def intent(scope, subscriber_id, item_id, intent, body) do
    case Relay.Inbox.apply_intent(scope, subscriber_id, item_id, intent) do
      {:conflict, state, _counters, _notification_id} ->
        {:error,
         Relay.Error.new(:inbox_item_conflict, "the item changed on another device", %{
           current: state
         })}

      {code, state, counters, notification_id} ->
        _ = signal(scope, subscriber_id, intent.op, code, {counters, notification_id})
        {:ok, {200, [], intent_view(intent, body, code, state, counters)}}

      :invalid ->
        {:error,
         failed([error("/snooze_until", "invalid_format", "a future time within 366 days")])}

      :not_found ->
        {:error, not_found()}
    end
  end

  # IN-38
  # IN-35
  defp signal(scope, subscriber_id, op, :applied, {counters, notification_id})
       when op in ["read", "click"] and notification_id != nil,
       do: Relay.Devices.propagate_read(scope, subscriber_id, notification_id, badge(counters))

  defp signal(scope, subscriber_id, _op, :applied, {counters, _notification_id}),
    do: Relay.Devices.sync(scope, subscriber_id, badge(counters))

  defp signal(_scope, _subscriber_id, _op, _code, _changed), do: :ok

  defp badge(counters), do: Map.take(counters, [:version, :unseen, :unread])

  defp intent_view(intent, body, code, state, counters) do
    %{
      "object" => "inbox_intent_result",
      "item_id" => state["id"],
      "op" => intent.op,
      "client_seq" => body["client_seq"],
      "result" => Atom.to_string(code),
      "state" => state,
      "counters" => counters_view(counters)
    }
  end

  defp counters_view(counters) do
    %{
      "object" => "inbox_counters",
      "unseen" => counters.unseen,
      "unread" => counters.unread,
      "total" => counters.total,
      "version" => counters.version
    }
  end

  # IN-50
  # IN-14
  # X-17
  # IN-35
  @doc "Marks the subscriber's unread items of the inbox tab read, all or of one `category`, up to the request's server time, inside the request's transaction (IN-50); the devices get a sync signal."
  @spec read_all(Relay.Scope.t(), Relay.Id.t(), map()) :: answer()
  def read_all(scope, subscriber_id, body) do
    with {:ok, category} <- category(body["category"]) do
      result = Relay.Inbox.read_all(scope, subscriber_id, category)
      _ = Relay.Devices.sync(scope, subscriber_id, badge(result.counters))

      {:ok,
       {200, [],
        %{
          "object" => "inbox_read_all_result",
          "scope" => if(category, do: "category", else: "all"),
          "category" => category,
          "updated" => result.updated,
          "cut_off" => result.cut_off,
          "counters" => counters_view(result.counters)
        }}}
    end
  end

  defp category(nil), do: {:ok, nil}

  defp category(value) do
    if text?(value, 128),
      do: {:ok, value},
      else: {:error, failed([error("/category", "invalid_format", "at most 128 characters")])}
  end

  # IN-14
  @doc "Starts an asynchronous bulk action over the subscriber's items matching a list filter, inside the request's transaction; answers `202` with the operation to follow."
  @spec start_bulk(Relay.Scope.t(), Relay.Id.t(), map()) :: answer()
  def start_bulk(scope, subscriber_id, body) do
    with :ok <- bulk_action(body["action"]),
         {:ok, filters} <- filters(Map.get(body, "filter") || %{}) do
      attrs = %{
        action: body["action"],
        status: Atom.to_string(filters[:status]),
        category: filters[:category],
        tag: filters[:tag]
      }

      id = Relay.Inbox.start_bulk(scope, subscriber_id, attrs)
      text = Relay.ExternalId.encode("ibk", id)
      location = "/v1/subscriber/inbox/bulk/" <> text

      {:ok,
       {202, [{"location", location}],
        %{
          "object" => "inbox_bulk_operation",
          "id" => text,
          "action" => body["action"],
          "state" => "running",
          "matched" => 0,
          "updated" => 0
        }}}
    end
  end

  defp bulk_action(action) when action in @bulk_actions, do: :ok

  defp bulk_action(_action),
    do: {:error, failed([error("/action", "unsupported_value", "read, archive or hide")])}

  # IN-14
  @doc "A bulk action of the subscriber with its progress."
  @spec bulk(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: answer()
  def bulk(scope, subscriber_id, operation_id) do
    case Relay.Inbox.bulk(scope, subscriber_id, operation_id) do
      {:ok, row} -> {:ok, {200, [], bulk_view(row)}}
      :not_found -> {:error, bulk_not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp bulk_view(row) do
    %{
      "object" => "inbox_bulk_operation",
      "id" => Relay.ExternalId.encode("ibk", row["id"]),
      "action" => row["action"],
      "state" => row["state"],
      "matched" => row["matched_count"],
      "updated" => row["updated_count"]
    }
  end

  @doc "The error of a bulk operation that is not the subscriber's."
  @spec bulk_not_found() :: Relay.Error.t()
  def bulk_not_found,
    do: Relay.Error.new(:inbox_bulk_operation_not_found, "no such inbox bulk operation")

  # IN-21
  # IN-35
  @doc "Reconciles the subscriber's counters at once after its client found them inconsistent with the items it lists (IN-21); answers whether they were consistent or repaired, with the counters."
  @spec report_inconsistency(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def report_inconsistency(scope, subscriber_id) do
    {result, counters} = Relay.Inbox.reconcile(scope, subscriber_id)

    {:ok,
     {200, [],
      %{
        "object" => "inbox_reconciliation",
        "result" => Atom.to_string(result),
        "counters" => counters_view(counters)
      }}}
  end

  @doc "The error of an item that is not the subscriber's or not visible."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:inbox_item_not_found, "no such inbox item")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "the inbox cannot be read now")

  defp failed(errors),
    do: Relay.Error.new(:validation_failed, "the request breaks a field rule", %{errors: errors})

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
