defmodule Relay.Api.TestSends do
  @moduledoc """
  Test sends and the test recipient list (API-61, TP-38). The tenant adds a subscriber, or one of its devices, as a `pending` test recipient; the subscriber verifies it by confirming it with its own subscriber token, which it obtained from its own Access sign-in, within the verification window (`test_send.verification_window`). The list holds at most `test_send.max_test_recipients` pending and verified entries.

  `POST /v1/workflows/{key}/test` sends the workflow's published version to verified test recipients only, through the same send path as `POST /v1/events` (`Relay.Api.Events`): validation, idempotency, preferences, routing, templates and the kill switch all apply, and on the live plane the real provider sends it. The event and its notifications are marked `is_test`, so the usage records and product metrics count them apart; the send consumes the day's test quota (`test_send.max_notifications_per_day`) instead of the sending quota. A device entry narrows push and Web Push to its one device.
  """

  alias Relay.Api.Events
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @max Relay.Limits.fetch!(["test_send", "max_test_recipients"])
  @window_s Relay.Limits.seconds!(["test_send", "verification_window"])
  @fields ~w(data channels overrides metadata)

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # API-61
  @doc "The API view of a test recipient row with its subscriber's external identifier."
  @spec view(map(), String.t() | nil) :: map()
  def view(row, external_id) do
    %{
      "object" => "test_recipient",
      "id" => Views.id("trc", row["id"]),
      "subscriber_id" => external_id,
      "device_id" => Views.id("dev", row["device_id"]),
      "state" => state(row),
      "verify_by" => row["verify_by"],
      "verified_at" => row["verified_at"],
      "removed_at" => row["removed_at"],
      "created_at" => row["created_at"]
    }
  end

  defp state(%{"state" => "pending", "verify_by" => %DateTime{} = at}) do
    if DateTime.compare(at, Relay.Clock.utc_now()) == :gt, do: "pending", else: "expired"
  end

  defp state(%{"state" => state}), do: state

  # API-61
  @doc "Lists the pending and verified test recipients of the scope, or with `recipient_id` only that subscriber's own."
  @spec list(Scope.t(), Relay.Id.t() | nil) :: answer()
  def list(%Scope{} = scope, recipient_id) do
    read = fn _status -> Relay.Ingest.test_recipients(recipient_id) end

    with {:ok, rows} <- Relay.Ingest.in_event_scope(scope, read),
         {:ok, names} <- names(scope, rows) do
      data = Enum.map(rows, &view(&1, names[&1["recipient_id"]]))
      {:ok, {200, [], Pagination.envelope(data, false, nil, nil)}}
    else
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp names(_scope, []), do: {:ok, %{}}

  defp names(scope, rows) do
    ids = rows |> Enum.map(& &1["recipient_id"]) |> Enum.uniq()

    case Relay.Subscribers.external_ids(scope, ids) do
      {:ok, names} -> {:ok, names}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # API-61
  @doc "Prepares adding a test recipient outside any transaction: the subscriber is located by its external identifier."
  @spec prepare_create(Scope.t(), map()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_create(%Scope{} = scope, body) do
    external_id = body["subscriber_id"]

    with {:ok, recipient_id} <- subscriber(scope, external_id),
         {:ok, device_id} <- device(body["device_id"]) do
      {:ok, %{recipient_id: recipient_id, device_id: device_id, external_id: external_id}}
    end
  end

  defp subscriber(scope, external_id) do
    case Relay.Subscribers.locate(scope, external_id) do
      {:ok, nil} -> {:error, subscriber_not_found()}
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp device(nil), do: {:ok, nil}

  defp device(text) do
    case Relay.ExternalId.decode(text, ["dev"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, device_not_found()}
    end
  end

  # API-61
  # TN-46
  @doc "Adds a prepared test recipient as pending inside the request's transaction: `201`, or `200` with the entry already listed."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, prepared, actor) do
    ref = Relay.Id.to_string(prepared.recipient_id)
    digest = digest(scope, "test_recipient.added", ref)
    %{recipient_id: recipient_id, device_id: device_id} = prepared
    limits = {@max, @window_s}

    case add(recipient_id, device_id, limits, digest, actor) do
      {:added, id} ->
        {:ok, {201, [], view(Relay.Ingest.test_recipient(id), prepared.external_id)}}

      {:exists, id} ->
        {:ok, {200, [], view(Relay.Ingest.test_recipient(id), prepared.external_id)}}

      {:limit_reached, _id} ->
        message = "the test recipient list holds at most #{@max} entries"
        {:error, Relay.Error.new(:test_recipient_limit_reached, message, %{limit: @max})}

      {:recipient_not_found, _id} ->
        {:error, subscriber_not_found()}

      {:device_not_found, _id} ->
        {:error, device_not_found()}
    end
  end

  defp add(recipient_id, device_id, {max, window_s}, digest, actor),
    do: Relay.Ingest.test_recipient_add(recipient_id, device_id, max, window_s, digest, actor)

  # API-61
  @doc "Reads a test recipient and its subscriber's external identifier outside any transaction; with `recipient_id` only that subscriber's own entry is found. A removed entry is found only without `recipient_id`."
  @spec prepare_entry(Scope.t(), Relay.Id.t(), Relay.Id.t() | nil) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def prepare_entry(%Scope{} = scope, id, recipient_id) do
    case Relay.Ingest.in_event_scope(scope, fn _status -> Relay.Ingest.test_recipient(id) end) do
      {:ok, %{} = row} -> entry(scope, row, recipient_id)
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp entry(scope, row, nil) do
    with {:ok, names} <- names(scope, [row]),
         do: {:ok, %{id: row["id"], external_id: names[row["recipient_id"]]}}
  end

  defp entry(scope, %{"recipient_id" => owner, "state" => state} = row, owner)
       when state != "removed",
       do: entry(scope, row, nil)

  defp entry(_scope, _row, _recipient_id), do: {:error, not_found()}

  # API-61
  # TN-46
  @doc "Removes a prepared test recipient inside the request's transaction; removing a removed one returns it."
  @spec remove(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def remove(%Scope{} = scope, entry, actor) do
    digest = digest(scope, "test_recipient.removed", Relay.Id.to_string(entry.id))

    case Relay.Ingest.test_recipient_remove(entry.id, digest, actor) do
      :not_found -> {:error, not_found()}
      _removed -> {:ok, {200, [], view(Relay.Ingest.test_recipient(entry.id), entry.external_id)}}
    end
  end

  # API-61
  # TN-46
  @doc "Confirms a prepared pending entry of the subscriber `recipient_id` inside the request's transaction; confirming a verified one returns it."
  @spec confirm(Scope.t(), map(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def confirm(%Scope{} = scope, entry, recipient_id, actor) do
    digest = digest(scope, "test_recipient.verified", Relay.Id.to_string(entry.id))

    case Relay.Ingest.test_recipient_confirm(entry.id, recipient_id, digest, actor) do
      result when result in [:verified, :already_verified] ->
        {:ok, {200, [], view(Relay.Ingest.test_recipient(entry.id), entry.external_id)}}

      _expired_or_gone ->
        {:error, not_found()}
    end
  end

  # API-61
  # TP-38
  @doc "Prepares a test send of a workflow's published version to verified test recipients outside any transaction; the prepared event is marked `is_test` and carries the device each device entry narrows push to."
  @spec prepare_send(Events.context(), String.t(), map()) ::
          {:ok, Events.prepared()} | {:error, Relay.Error.t()}
  def prepare_send(%{scope: scope} = ctx, key, body) do
    texts = body["to"]

    with :ok <- workflow(scope, key),
         {:ok, rows} <- verified(scope, texts),
         {:ok, names} <- names(scope, rows),
         {:ok, to} <- targets(texts, rows, names),
         {:ok, prepared} <- Events.prepare(ctx, event_body(key, body, to)) do
      {:ok, Map.merge(prepared, %{is_test: true, test_devices: devices(rows)})}
    end
  end

  defp workflow(scope, key) do
    case Relay.Workflow.resolve_published(scope, key) do
      {:ok, :not_found} -> {:error, workflow_not_found()}
      _found_or_unavailable -> :ok
    end
  end

  defp verified(scope, texts) do
    ids = for text <- texts, {:ok, id} <- [Relay.ExternalId.decode(text, ["trc"])], do: id
    read = fn _status -> Relay.Ingest.verified_test_recipients(ids) end

    case Relay.Ingest.in_event_scope(scope, read) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp targets(texts, rows, names) do
    by_id = Map.new(rows, &{Views.id("trc", &1["id"]), names[&1["recipient_id"]]})

    errors =
      for {text, index} <- Enum.with_index(texts), Map.get(by_id, text) == nil do
        detail = "not a verified test recipient"
        %{pointer: "/to/#{index}", code: "not_allowed", detail: detail}
      end

    message = "not every test recipient is verified"

    if errors == [],
      do: {:ok, texts |> Enum.map(&Map.fetch!(by_id, &1)) |> Enum.uniq()},
      else: {:error, Relay.Error.new(:recipient_invalid, message, %{errors: errors})}
  end

  defp event_body(key, body, to),
    do: body |> Map.take(@fields) |> Map.merge(%{"workflow" => key, "to" => to})

  defp devices(rows) do
    rows
    |> Enum.group_by(& &1["recipient_id"], & &1["device_id"])
    |> Enum.reject(fn {_recipient_id, devices} -> nil in devices end)
    |> Map.new(fn {recipient_id, [device_id | _]} -> {recipient_id, device_id} end)
  end

  # API-61
  @doc "Accepts a prepared test send inside the request's idempotency transaction; `202` with the event's location."
  @spec accept_send(Events.prepared(), Events.context()) :: answer()
  def accept_send(prepared, ctx) do
    with {:ok, body} <- Events.accept(prepared, ctx),
         do: {:ok, {202, [{"location", "/v1/events/" <> body["id"]}], body}}
  end

  defp digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  @doc "The error of an unknown test recipient."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:test_recipient_not_found, "no such test recipient")

  defp workflow_not_found, do: Relay.Error.new(:workflow_not_found, "no workflow has this key")

  defp subscriber_not_found,
    do: Relay.Error.new(:subscriber_not_found, "no subscriber has this id")

  defp device_not_found, do: Relay.Error.new(:device_not_found, "no such device")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
