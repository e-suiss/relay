defmodule Relay.Api.WebhookConsumers do
  @moduledoc """
  Webhook consumers on the server API (WH-2): the customers of a tenant that receive events of use `destination`. A consumer is listed, created (`201`), read, changed with a JSON Merge Patch under an optional `If-Match`, and archived; nothing is deleted, and a consumer that still has an endpoint is not archived. The writes run inside the request's transaction and are audited.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @states ~w(active archived)

  # WH-2
  @doc "The API view of a consumer row."
  @spec view(map()) :: map()
  def view(c) do
    %{
      "object" => "webhook_consumer",
      "id" => Views.id("whc", c["id"]),
      "key" => c["key"],
      "name" => c["name"],
      "source" => c["source"],
      "subtenant_id" => Views.id("stn", c["subtenant_id"]),
      "state" => c["state"],
      "version" => c["version"],
      "created_at" => c["created_at"],
      "updated_at" => c["updated_at"],
      "archived_at" => c["archived_at"]
    }
  end

  @doc "The ETag header of a version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # WH-2
  @doc "Reads the `state` filter of a list request."
  @spec filters(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def filters(query) do
    case Map.get(query, "state") do
      state when state == nil or state in @states -> {:ok, state}
      _other -> {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}
    end
  end

  # WH-2
  @doc "Creates a consumer inside the request's transaction; `201` with its view."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, body, actor) do
    with {:ok, subtenant_id} <- subtenant(body["subtenant_id"]) do
      attrs = %{
        key: body["key"],
        name: body["name"],
        source: body["source"],
        subtenant_id: subtenant_id
      }

      digest = Gate.digest(scope, "webhook_consumer.created", attrs.key)
      created(Relay.Webhooks.consumer_create(attrs, digest, actor))
    end
  end

  defp created({:created, id, version}) do
    location = {"location", "/v1/webhook_consumers/" <> Views.id("whc", id)}
    {:ok, {201, [etag(version), location], view(Relay.Webhooks.consumer(id))}}
  end

  defp created({:key_conflict, _id, _version}),
    do: {:error, Relay.Error.new(:resource_conflict, "a consumer with this key exists")}

  defp created({:subtenant_not_found, _id, _version}), do: {:error, no_subtenant()}

  defp created({:tenant_inactive, _id, _version}), do: {:error, suspended()}

  defp subtenant(nil), do: {:ok, nil}

  defp subtenant(text) do
    case Relay.ExternalId.decode(text, ["stn"]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, no_subtenant()}
    end
  end

  # WH-2
  @doc "Reads a consumer."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    case Relay.Webhooks.get_consumer(scope, id) do
      {:ok, %{} = consumer} -> {:ok, {200, [etag(consumer["version"])], view(consumer)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-2
  # API-56
  @doc "Lists consumers, newest first."
  @spec list(Scope.t(), String.t() | nil, Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, state, page, endpoint) do
    case Relay.Webhooks.list_consumers(scope, state, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-2
  @doc "Applies a JSON Merge Patch to a consumer inside the request's transaction; `expected_version` is the version an `If-Match` named, or `nil`."
  @spec update(Scope.t(), Relay.Id.t(), map(), pos_integer() | nil, Relay.Actor.t()) :: answer()
  def update(%Scope{} = scope, id, body, expected_version, actor) do
    changes = Map.take(body, ["name", "source"])
    digest = Gate.digest(scope, "webhook_consumer.updated", Relay.Id.to_string(id))

    case Relay.Webhooks.consumer_update(id, expected_version, changes, digest, actor) do
      {result, version} when result in [:updated, :unchanged] ->
        {:ok, {200, [etag(version)], view(Relay.Webhooks.consumer(id))}}

      {:version_conflict, _version} ->
        {:error, Relay.Error.new(:precondition_failed, "the consumer changed; read it again")}

      {:archived, _version} ->
        {:error, archived()}

      {:not_found, _version} ->
        {:error, not_found()}
    end
  end

  # WH-2
  @doc "Archives a consumer inside the request's transaction; archiving an archived consumer returns it."
  @spec archive(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def archive(%Scope{} = scope, id, actor) do
    digest = Gate.digest(scope, "webhook_consumer.archived", Relay.Id.to_string(id))

    case Relay.Webhooks.consumer_archive(id, digest, actor) do
      {result, _version} when result in [:archived, :already_archived] ->
        {:ok, {200, [], view(Relay.Webhooks.consumer(id))}}

      {:in_use, _version} ->
        {:error, Relay.Error.new(:webhook_consumer_in_use, "the consumer still has endpoints")}

      {:not_found, _version} ->
        {:error, not_found()}
    end
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown consumer identifier."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:webhook_consumer_not_found, "no consumer has this id")

  @doc "The error of an archived consumer."
  @spec archived() :: Relay.Error.t()
  def archived, do: Relay.Error.new(:webhook_consumer_archived, "the consumer is archived")

  defp no_subtenant,
    do: Gate.field_error("/subtenant_id", "not_found", "no subtenant has this id")

  defp suspended, do: Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")
  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
