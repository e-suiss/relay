defmodule Relay.Api.Queries do
  @moduledoc """
  The query operations (API-56, DS-15): an event with its notifications, notifications under filters (subscriber, workflow, delivery status, creation time) with cursor pagination, one notification with optional deliveries, the deliveries of a notification and a delivery's attempts and ledger. Statuses are the external projection; raw provider responses stay masked.
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @statuses ~w(queued sent delivered unknown_pending unknown failed skipped expired cancelled)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # API-19
  @doc "Reads an event with its notifications."
  @spec event(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def event(scope, id) do
    case Relay.Ingest.in_event_scope(scope, fn _status -> Relay.Ingest.event(id) end) do
      {:ok, %{} = event} -> {:ok, {200, [], event_view(scope, event)}}
      {:ok, nil} -> {:error, Relay.Error.new(:event_not_found, "no such event")}
      {:error, _reason} -> {:error, Relay.Error.new(:event_not_found, "no such event")}
    end
  end

  defp event_view(scope, e) do
    payload = e["payload"] || %{}
    open = fn column -> open(scope, payload["key_id"], column, payload[column]) end
    ce = open.("ce_attributes_ct")

    %{
      "object" => "event",
      "id" => Views.id("evt", e["id"]),
      "workflow" => %{"key" => e["workflow_key"], "version" => e["workflow_version"]},
      "status" => e["state"],
      "source" => e["source"],
      "cloudevent" => ce && Map.take(ce, ["source", "id", "type"]),
      "tenant" => Views.id("stn", e["subtenant_id"]),
      "actor" => open.("actor_ct"),
      "dedup_key" => e["dedup_key"],
      "cancellation_key" => e["cancellation_key"],
      "send_at" => e["send_at"],
      "expires_at" => e["expires_at"],
      "priority" => e["priority"],
      "recipient_count" => e["recipient_count"],
      "notifications" => Enum.map(e["notifications"], &accepted/1),
      "is_test" => e["is_test"],
      "created_at" => e["created_at"],
      "cancelled_at" => e["cancelled_at"]
    }
    |> Views.put_unless_nil("metadata", open.("metadata_ct"))
  end

  defp accepted(n) do
    prefix = Views.recipient_prefix(n["recipient_kind"])

    %{
      "recipient_id" => Views.id(prefix, n["recipient_id"]),
      "notification_id" => Views.id("ntf", n["id"])
    }
  end

  defp open(_scope, _key_id, _column, nil), do: nil

  defp open(scope, key_id, column, ct) do
    field = %{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      retention_class: :notification_content,
      table: "event_payloads",
      column: column,
      key_id: key_id
    }

    with {:ok, plain} <- Relay.Tenancy.decrypt_field(field, ct),
         {:ok, value} <- Jason.decode(Relay.Redacted.expose(plain)) do
      value
    else
      _ -> nil
    end
  end

  # API-56
  @doc "Reads the filters of a notification list; every invalid one is reported."
  @spec filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def filters(query) do
    checks = [
      {"status", :status, &status/1},
      {"created_after", :created_after, &time/1},
      {"created_before", :created_before, &time/1},
      {"workflow", :workflow, &key/1},
      {"subscriber", :subscriber, &external_id/1}
    ]

    {filters, errors} =
      Enum.reduce(checks, {%{}, []}, fn {name, field, check}, {acc, errors} ->
        with {:ok, value} <- Map.fetch(query, name),
             {:ok, cast} <- check.(value) do
          {Map.put(acc, field, cast), errors}
        else
          :error when is_map_key(query, name) -> {acc, [invalid(name) | errors]}
          :error -> {acc, errors}
        end
      end)

    if errors == [],
      do: {:ok, filters},
      else: {:error, Relay.Error.new(:validation_failed, "invalid filters", %{errors: errors})}
  end

  defp invalid(name), do: %{pointer: "/" <> name, code: "invalid_format", detail: name}

  defp status(value), do: if(value in @statuses, do: {:ok, value}, else: :error)

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> :error
    end
  end

  defp time(_value), do: :error

  defp key(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/, value) and byte_size(value) <= 100,
      do: {:ok, value},
      else: :error
  end

  defp key(_value), do: :error

  defp external_id(value) when is_binary(value) do
    if Regex.match?(~r/\A[\x21-\x7E]{1,256}\z/, value), do: {:ok, value}, else: :error
  end

  defp external_id(_value), do: :error

  # API-21
  @doc "The blind indexes of external identifiers, outside any transaction."
  @spec indexes(Relay.Scope.t(), [String.t()]) :: {:ok, [binary()]} | {:error, term()}
  defdelegate indexes(scope, external_ids), to: Relay.Subscribers

  # API-56
  @doc "Lists notifications under the filters of `filters/1`."
  @spec notifications(Relay.Scope.t(), map(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def notifications(scope, filters, page, endpoint) do
    {subscriber, filters} = Map.pop(filters, :subscriber)

    with {:ok, indexes} <- if(subscriber, do: indexes(scope, [subscriber]), else: {:ok, nil}),
         read = fn _status -> read_notifications(filters, indexes, page) end,
         {:ok, rows} <- Relay.Ingest.in_event_scope(scope, read),
         {:ok, body} <-
           Page.envelope(rows, page, scope, endpoint, &Views.notification/1, &position/1) do
      {:ok, {200, [], body}}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  defp read_notifications(filters, nil, page),
    do: Relay.Ingest.notifications(filters, page.cursor, page.limit)

  defp read_notifications(filters, indexes, page) do
    ids = Relay.Subscribers.resolve_indexes(indexes)
    Relay.Ingest.notifications(Map.put(filters, :recipient_ids, ids), page.cursor, page.limit)
  end

  # API-56
  @doc "Reads a notification, with its deliveries when `expand` asks for them."
  @spec notification(Relay.Scope.t(), Relay.Id.t(), boolean()) :: answer()
  def notification(scope, id, expand?) do
    read = fn _status ->
      case Relay.Ingest.notification(id) do
        nil -> nil
        n -> {n, if(expand?, do: Enum.take(Relay.Ingest.deliveries(id, nil, 100), 100))}
      end
    end

    case Relay.Ingest.in_event_scope(scope, read) do
      {:ok, {n, deliveries}} -> {:ok, {200, [], Views.notification(n, deliveries)}}
      _ -> {:error, Relay.Error.new(:notification_not_found, "no such notification")}
    end
  end

  # API-56
  @doc "Lists the deliveries of a notification."
  @spec deliveries(Relay.Scope.t(), Relay.Id.t(), Relay.Api.Pagination.page(), String.t()) ::
          answer()
  def deliveries(scope, notification_id, page, endpoint) do
    read = fn _status ->
      if Relay.Ingest.notification(notification_id),
        do: Relay.Ingest.deliveries(notification_id, page.cursor, page.limit)
    end

    case Relay.Ingest.in_event_scope(scope, read) do
      {:ok, rows} when is_list(rows) ->
        with {:ok, body} <-
               Page.envelope(rows, page, scope, endpoint, &Views.delivery/1, &position/1),
             do: {:ok, {200, [], body}}

      _ ->
        {:error, Relay.Error.new(:notification_not_found, "no such notification")}
    end
  end

  # DS-15
  @doc "Reads a delivery with its attempts and ledger."
  @spec history(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def history(scope, id) do
    read = fn _status ->
      case Relay.Ingest.delivery(id) do
        nil -> nil
        d -> {d, Relay.Ingest.attempts(id), Relay.Ingest.ledger(id)}
      end
    end

    case Relay.Ingest.in_event_scope(scope, read) do
      {:ok, {d, attempts, events}} ->
        {:ok,
         {200, [],
          %{
            "object" => "delivery_history",
            "delivery" => Views.delivery(d),
            "attempts" => Enum.map(attempts, &attempt/1),
            "events" => Enum.map(events, &ledger_event/1)
          }}}

      _ ->
        {:error, Relay.Error.new(:delivery_not_found, "no such delivery")}
    end
  end

  defp attempt(a) do
    %{
      "object" => "attempt",
      "id" => Views.id("att", a["id"]),
      "attempt_no" => a["attempt_no"],
      "state" => a["state"],
      "provider" => a["provider"],
      "failure_class" => a["failure_class"],
      "raw_code" => nil,
      "started_at" => a["started_at"],
      "finished_at" => a["finished_at"]
    }
  end

  defp ledger_event(e) do
    %{
      "object" => "delivery_event",
      "id" => Views.id("dle", e["id"]),
      "actor" => e["actor"],
      "type" => e["event_type"],
      "attempt_no" => e["attempt_no"],
      "raw_code" => nil,
      "provider" => e["provider"],
      "occurred_at" => e["occurred_at"],
      "received_at" => e["received_at"]
    }
  end

  defp position(row), do: {row["created_at"], row["id"]}
end
