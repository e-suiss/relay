defmodule Relay.Api.WebhookEventTypes do
  @moduledoc """
  Tenant event types on the server API (WH-13, WH-14): the event types of use `destination`, each with versioned schemas. A type is listed, created with its first schema version (`201`), read and archived; a schema change opens a new version and never edits one. The schema is a JSON Schema 2020-12 document that is only validated against, its identifiers are properties it declares and its example is valid against it. The writes run inside the request's transaction and are audited.
  """

  alias Relay.Api.Gate
  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.Api.Views
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @states ~w(active archived)

  # WH-14
  @doc "The API view of an event type row with its current schema version."
  @spec view(map()) :: map()
  def view(t) do
    %{
      "object" => "webhook_event_type",
      "id" => Views.id("wet", t["id"]),
      "name" => t["name"],
      "description" => t["description"],
      "state" => t["state"],
      "version" => t["current_version"],
      "schema" => t["json_schema"],
      "identifiers" => t["identifiers"],
      "example" => t["example"],
      "created_at" => t["created_at"],
      "updated_at" => t["updated_at"],
      "archived_at" => t["archived_at"]
    }
  end

  # WH-14
  @doc "The API view of one schema version."
  @spec version_view(map()) :: map()
  def version_view(v) do
    %{
      "object" => "webhook_event_type_version",
      "event_type_id" => Views.id("wet", v["event_type_id"]),
      "name" => v["name"],
      "version" => v["version"],
      "schema" => v["json_schema"],
      "identifiers" => v["identifiers"],
      "example" => v["example"],
      "created_at" => v["created_at"]
    }
  end

  # WH-14
  @doc "Reads the `state` filter of a list request."
  @spec filters(map()) :: {:ok, String.t() | nil} | {:error, Relay.Error.t()}
  def filters(query) do
    case Map.get(query, "state") do
      state when state == nil or state in @states -> {:ok, state}
      _other -> {:error, Gate.field_error("/state", "unsupported_value", "unknown state")}
    end
  end

  # WH-13
  # WH-14
  @doc "Creates an event type with its first schema version inside the request's transaction; `201` with its view."
  @spec create(Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(%Scope{} = scope, body, actor) do
    with {:ok, version} <- checked(body) do
      attrs = Map.merge(version, %{name: body["name"], description: body["description"]})
      digest = Gate.digest(scope, "webhook_event_type.created", attrs.name)

      case Relay.Webhooks.event_type_create(attrs, digest, actor) do
        {:created, id} ->
          location = {"location", "/v1/webhook_event_types/" <> Views.id("wet", id)}
          {:ok, {201, [location], view(Relay.Webhooks.event_type(id))}}

        {:name_conflict, _id} ->
          {:error, Relay.Error.new(:resource_conflict, "an event type with this name exists")}

        {:tenant_inactive, _id} ->
          {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
      end
    end
  end

  # WH-14
  @doc "Opens the next schema version of an event type inside the request's transaction: `201` with the new version, `200` with the current one when nothing changed."
  @spec add_version(Scope.t(), Relay.Id.t(), map(), Relay.Actor.t()) :: answer()
  def add_version(%Scope{} = scope, id, body, actor) do
    with {:ok, version} <- checked(body) do
      digest = Gate.digest(scope, "webhook_event_type.version_added", Relay.Id.to_string(id))

      case Relay.Webhooks.event_type_version_add(id, version, digest, actor) do
        {:added, number} -> {:ok, {201, [], version_view(stored(id, number))}}
        {:unchanged, number} -> {:ok, {200, [], version_view(stored(id, number))}}
        {:archived, _number} -> {:error, archived()}
        {:not_found, _number} -> {:error, not_found()}
      end
    end
  end

  defp stored(id, number), do: Relay.Webhooks.event_type_version(id, number)

  defp checked(body) do
    schema = body["schema"]
    identifiers = Map.get(body, "identifiers", [])
    example = body["example"]

    case Relay.Webhooks.check_event_schema(schema, identifiers, example) do
      {:ok, digest} ->
        {:ok,
         %{schema: schema, schema_digest: digest, identifiers: identifiers, example: example}}

      {:error, reason} ->
        {:error, refused(reason)}
    end
  end

  defp refused(:too_large),
    do: Gate.field_error("/schema", "too_long", "the schema or the example is too large")

  defp refused(:not_a_schema),
    do: Gate.field_error("/schema", "invalid_format", "not a JSON Schema 2020-12 document")

  defp refused({:identifier, name}),
    do: Gate.field_error("/identifiers", "not_found", "the schema declares no property " <> name)

  defp refused(:example),
    do: Gate.field_error("/example", "invalid_format", "the example is not valid against schema")

  # WH-14
  @doc "Reads an event type."
  @spec get(Scope.t(), Relay.Id.t()) :: answer()
  def get(%Scope{} = scope, id) do
    case Relay.Webhooks.get_event_type(scope, id) do
      {:ok, %{} = type} -> {:ok, {200, [], view(type)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-14
  # API-56
  @doc "Lists event types, newest first."
  @spec list(Scope.t(), String.t() | nil, Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, state, page, endpoint) do
    case Relay.Webhooks.list_event_types(scope, state, page.cursor, page.limit) do
      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-14
  @doc "Reads one schema version of an event type."
  @spec get_version(Scope.t(), Relay.Id.t(), pos_integer()) :: answer()
  def get_version(%Scope{} = scope, id, version) do
    case Relay.Webhooks.get_event_type_version(scope, id, version) do
      {:ok, %{} = row} -> {:ok, {200, [], version_view(row)}}
      {:ok, nil} -> {:error, not_found()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  # WH-14
  # API-56
  @doc "Lists the schema versions of an event type, newest first."
  @spec versions(Scope.t(), Relay.Id.t(), Pagination.page(), String.t()) :: answer()
  def versions(%Scope{} = scope, id, page, endpoint) do
    position = &{DateTime.from_unix!(&1["version"], :microsecond), &1["event_type_id"]}

    case Relay.Webhooks.list_event_type_versions(scope, id, page.cursor, page.limit) do
      {:ok, :not_found} ->
        {:error, not_found()}

      {:ok, rows} ->
        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &version_view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, unavailable()}
    end
  end

  # WH-14
  @doc "Archives an event type inside the request's transaction; archiving an archived type returns it."
  @spec archive(Scope.t(), Relay.Id.t(), Relay.Actor.t()) :: answer()
  def archive(%Scope{} = scope, id, actor) do
    digest = Gate.digest(scope, "webhook_event_type.archived", Relay.Id.to_string(id))

    case Relay.Webhooks.event_type_archive(id, digest, actor) do
      {result, _version} when result in [:archived, :already_archived] ->
        {:ok, {200, [], view(Relay.Webhooks.event_type(id))}}

      {:not_found, _version} ->
        {:error, not_found()}
    end
  end

  defp position(row), do: {row["cursor_at"], row["id"]}

  @doc "The error of an unknown event type identifier or version."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:webhook_event_type_not_found, "no event type has this id")

  defp archived,
    do: Relay.Error.new(:webhook_event_type_archived, "the event type is archived")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
