defmodule Relay.Api.WebhookMessages do
  @moduledoc """
  The delivery log and the recovery operations on the server API (WH-10, WH-27, WH-30, WH-31, WH-32, WH-33, WH-48): the messages of the environment and the events an endpoint missed, paged newest first with their filters; the attempts of a message in attempt order, and one attempt with the first bytes of its answer while that is kept; the resend and the cancellation of one message; and `recover`, the filtered bulk retry, the replay and the cancellation of scheduled retries on an endpoint.

  A recovery operation on an endpoint answers how many messages it selected and does its work in jobs, at a controlled rate within the endpoint's limits (WH-33 (2)). Every operation that changes something writes its audit record in the request's transaction (WH-48) and keeps the event identifier of every message it touches (WH-33 (1)).
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Api.Webhooks
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @states ~w(pending scheduled in_flight held delivered failed_permanent exhausted expired
             window_exceeded dead_lettered cancelled)
  @event_name ~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/
  @fields %{
    "endpoint_id" => :endpoint_id,
    "event_id" => :event_id,
    "state" => :state,
    "event_type" => :event_type,
    "created_after" => :created_after,
    "created_before" => :created_before
  }
  @log_filters ~w(endpoint_id event_id state event_type created_after created_before)
  @missed_filters ~w(event_type created_after created_before)

  # WH-2
  # WH-33 (1)
  @doc "The API view of a message of the delivery log; `event_id` is the `webhook-id` its consumer deduplicates by."
  @spec view(map()) :: map()
  def view(m) do
    %{
      "object" => "webhook_message",
      "id" => Views.id("whm", m["id"]),
      "endpoint_id" => Views.id("whe", m["endpoint_id"]),
      "endpoint_version" => m["endpoint_version"],
      "event_id" => m["webhook_id"],
      "event_type" => m["event_type"],
      "origin" => m["origin"],
      "state" => m["state"],
      "hold_reason" => m["hold_reason"],
      "reason" => m["reason"],
      "attempt_count" => m["total_attempt_count"],
      "next_attempt_at" => m["next_attempt_at"],
      "last_attempt_at" => m["last_attempt_at"],
      "last_response_status" => m["last_response_status"],
      "delivered_at" => m["delivered_at"],
      "expires_at" => m["expires_at"],
      "created_at" => m["created_at"],
      "updated_at" => m["updated_at"]
    }
  end

  # WH-10
  # WH-19
  @doc "The API view of an attempt without its answer."
  @spec attempt_view(map()) :: map()
  def attempt_view(a) do
    %{
      "object" => "webhook_attempt",
      "id" => Views.id("wha", a["id"]),
      "message_id" => Views.id("whm", a["message_id"]),
      "endpoint_id" => Views.id("whe", a["endpoint_id"]),
      "attempt_no" => a["attempt_no"],
      "trigger" => a["trigger_kind"],
      "result" => a["result"],
      "failure_code" => a["failure_code"],
      "response_status" => a["response_status"],
      "duration_ms" => a["duration_ms"],
      "webhook_timestamp" => a["webhook_timestamp"],
      "body_digest" => Gate.hex(a["body_digest"]),
      "signature" => a["signature"],
      "destination_ip" => a["destination_ip"],
      "retry_after" => a["retry_after_seconds"] && Webhooks.iso(a["retry_after_seconds"]),
      "started_at" => a["started_at"],
      "finished_at" => a["finished_at"]
    }
  end

  # WH-10
  # WH-30
  defp answered(a), do: a |> attempt_view() |> Map.put("response_body", body(a["response"]))

  defp body(nil), do: nil

  defp body(%{body: redacted, truncated: truncated}) do
    content = Relay.Redacted.expose(redacted)

    {encoding, content} =
      if String.valid?(content), do: {"utf8", content}, else: {"base64", Base.encode64(content)}

    %{"encoding" => encoding, "content" => content, "truncated" => truncated}
  end

  # API-56
  @doc "Reads the filters of the delivery log: `endpoint_id`, `event_id`, `state`, `event_type`, `created_after` and `created_before`. Every invalid one is reported."
  @spec filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def filters(query), do: filters(query, @log_filters)

  # API-56
  @doc "Reads the filters of the missed events of an endpoint: `event_type`, `created_after` and `created_before`."
  @spec missed_filters(map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def missed_filters(query), do: filters(query, @missed_filters)

  defp filters(query, names) do
    {filters, errors} =
      Enum.reduce(names, {%{}, []}, fn name, {acc, errors} ->
        case cast(name, Map.get(query, name)) do
          :absent -> {acc, errors}
          {:ok, value} -> {Map.put(acc, Map.fetch!(@fields, name), value), errors}
          _invalid -> {acc, [invalid(name) | errors]}
        end
      end)

    if errors == [],
      do: {:ok, filters},
      else: {:error, Relay.Error.new(:validation_failed, "invalid filters", %{errors: errors})}
  end

  defp invalid(name), do: %{pointer: "/" <> name, code: "invalid_format", detail: name}

  defp cast(_name, nil), do: :absent
  defp cast("endpoint_id", text) when is_binary(text), do: Relay.ExternalId.decode(text, ["whe"])
  defp cast("event_id", "test_" <> uuid), do: Relay.Id.parse(uuid)
  defp cast("event_id", text) when is_binary(text), do: Relay.ExternalId.decode(text, ["oev"])
  defp cast("state", state) when state in @states, do: {:ok, state}

  defp cast("event_type", name) when is_binary(name) and byte_size(name) <= 128,
    do: if(Regex.match?(@event_name, name), do: {:ok, name}, else: :error)

  defp cast("created_" <> _edge, text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp cast(_name, _value), do: :error

  # WH-30 (3)
  # API-56
  @doc "Lists the messages of the environment, newest first."
  @spec list(Scope.t(), map(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, filters, page, endpoint) do
    scope
    |> Relay.Webhooks.list_messages(filters, page.cursor, page.limit)
    |> paged(page, scope, endpoint, Webhooks.not_found())
  end

  # WH-30 (2)
  # WH-37
  # API-56
  @doc "Lists the events an endpoint missed, newest first: its messages in a terminal state other than `delivered` and those kept while it was disabled."
  @spec missed(Scope.t(), Relay.Id.t(), map(), Pagination.page(), String.t()) :: answer()
  def missed(%Scope{} = scope, endpoint_id, filters, page, endpoint) do
    scope
    |> Relay.Webhooks.list_missed(endpoint_id, filters, page.cursor, page.limit)
    |> paged(page, scope, endpoint, Webhooks.not_found())
  end

  defp paged({:ok, :not_found}, _page, _scope, _endpoint, not_found), do: {:error, not_found}
  defp paged({:error, _reason}, _page, _scope, _endpoint, _not_found), do: {:error, unavailable()}

  defp paged({:ok, rows}, page, scope, endpoint, _not_found) do
    position = &{&1["created_at"], &1["id"]}

    with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
         do: {:ok, {200, [], body}}
  end

  # WH-30 (3)
  @doc "Reads a message."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    case Relay.Webhooks.get_log_message(scope, id) do
      {:ok, %{} = message} -> {:ok, {200, [], view(message)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-10
  # API-56
  @doc "Lists the attempts of a message in attempt order, without their answers."
  @spec attempts(Scope.t(), Relay.Id.t(), Pagination.page(), String.t()) :: answer()
  def attempts(%Scope{} = scope, message_id, page, endpoint) do
    position = &{DateTime.from_unix!(&1["attempt_no"], :microsecond), &1["id"]}

    case Relay.Webhooks.list_attempts(scope, message_id, page.cursor, page.limit) do
      {:ok, :not_found} ->
        {:error, not_found()}

      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &attempt_view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-10
  # WH-19
  # WH-30
  @doc "Reads one attempt of a message with the first bytes of its answer, or `null` once the answer is no longer kept."
  @spec attempt(Scope.t(), Relay.Id.t(), Relay.Id.t()) :: answer()
  def attempt(%Scope{} = scope, message_id, attempt_id) do
    case Relay.Webhooks.get_attempt(scope, message_id, attempt_id) do
      {:ok, %{} = attempt} -> {:ok, {200, [], answered(attempt)}}
      {:ok, :not_found} -> {:error, not_found()}
      {:ok, nil} -> {:error, attempt_not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-31
  # WH-32
  # WH-48
  @doc "Resends a message inside the request's transaction: `202` with the message, whose one attempt is queued at once."
  @spec resend(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def resend(%Scope{} = scope, id, actor) do
    digest = Gate.digest(scope, "webhook_message.resent", Relay.Id.to_string(id))

    case Relay.Webhooks.message_resend(id, digest, actor) do
      {:ok, message} -> {:ok, {202, [], view(message)}}
      {:error, refusal} -> {:error, refused(refusal, not_found())}
    end
  end

  # WH-31
  # WH-48
  @doc "Cancels the waiting attempts of a message inside the request's transaction; a message in a terminal state is returned unchanged."
  @spec cancel(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def cancel(%Scope{} = scope, id, actor) do
    digest = Gate.digest(scope, "webhook_message.cancelled", Relay.Id.to_string(id))

    case Relay.Webhooks.message_cancel(id, digest, actor) do
      {:ok, message} -> {:ok, {200, [], view(message)}}
      {:error, refusal} -> {:error, refused(refusal, not_found())}
    end
  end

  # WH-31
  # WH-32 (3)
  # WH-33
  # WH-48
  @doc "Starts `operation` (`recover`, `retry`, `replay` or `cancel_retries`) on an endpoint inside the request's transaction: `200` with how many messages it selected. The selected messages are worked through by jobs."
  @spec recovery(Scope.t(), String.t(), Relay.Id.t(), map() | nil, Relay.Actor.t()) :: answer()
  def recovery(%Scope{} = scope, operation, endpoint_id, body, actor) do
    ref = operation <> ":" <> Relay.Id.to_string(endpoint_id)
    digest = Gate.digest(scope, "webhook_endpoint.recovery", ref)

    with {:ok, request} <- request(operation, endpoint_id, body || %{}),
         {:ok, selected} <- started(Relay.Webhooks.recovery_start(request, digest, actor)) do
      body = %{
        "object" => "webhook_recovery",
        "operation" => operation,
        "endpoint_id" => Views.id("whe", endpoint_id),
        "selected" => selected
      }

      {:ok, {200, [], body}}
    end
  end

  defp started({:ok, selected}), do: {:ok, selected}
  defp started({:error, refusal}), do: {:error, refused(refusal, Webhooks.not_found())}

  defp request(operation, endpoint_id, body) do
    with {:ok, since} <- time(body, "since"),
         {:ok, until} <- time(body, "until"),
         :ok <- in_order(since, until) do
      {:ok,
       %{
         operation: operation,
         endpoint_id: endpoint_id,
         since: since,
         until: until,
         event_types: body["event_types"],
         states: body["states"],
         reasons: body["reasons"]
       }}
    end
  end

  defp time(body, name) do
    case cast("created_" <> name, body[name]) do
      :absent -> {:ok, nil}
      {:ok, at} -> {:ok, at}
      _invalid -> {:error, Gate.field_error("/" <> name, "invalid_format", "not a timestamp")}
    end
  end

  defp in_order(%DateTime{} = since, %DateTime{} = until) do
    if DateTime.compare(since, until) == :lt,
      do: :ok,
      else: {:error, Gate.field_error("/until", "not_allowed", "until must be after since")}
  end

  defp in_order(_since, _until), do: :ok

  defp refused(:not_found, not_found), do: not_found

  defp refused(:archived, _not_found),
    do: Relay.Error.new(:webhook_endpoint_archived, "the endpoint is archived")

  defp refused(:state_conflict, _not_found) do
    detail = "the endpoint is paused or disabled"
    Relay.Error.new(:webhook_endpoint_state_conflict, detail)
  end

  defp refused(:in_flight, _not_found),
    do: Relay.Error.new(:webhook_message_in_flight, "an attempt of the message is running")

  defp refused(_unavailable, _not_found), do: unavailable()

  @doc "The error of an unknown message identifier."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:webhook_message_not_found, "no message has this id")

  @doc "The error of an attempt identifier the message does not have."
  @spec attempt_not_found() :: Relay.Error.t()
  def attempt_not_found,
    do: Relay.Error.new(:webhook_attempt_not_found, "the message has no attempt with this id")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
