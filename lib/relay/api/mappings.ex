defmodule Relay.Api.Mappings do
  @moduledoc """
  CloudEvents type mappings (API-28, API-29, MD-16): a tenant-defined link from a CloudEvents `type` (and optionally an exact `source`) to a workflow, with a recipient pointer, an optional sub-tenant pointer and an allow-list of data fields instead of a transformation script. One active mapping per type and source.
  """

  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @doc "The API view of a mapping."
  @spec view(map()) :: map()
  def view(m) do
    %{
      "object" => "event_type_mapping",
      "id" => Views.id("cem", m["id"]),
      "type" => m["type"],
      "source" => m["source"],
      "workflow" => m["workflow"],
      "to_pointer" => m["to_pointer"],
      "tenant_pointer" => m["tenant_pointer"],
      "data_fields" => m["data_fields"],
      "state" => m["state"],
      "version" => m["version"],
      "created_at" => m["created_at"],
      "updated_at" => m["updated_at"]
    }
  end

  @doc "The ETag header of a mapping version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # MD-16
  @doc "Checks the pointers of a mapping write; every invalid pointer is reported."
  @spec check(map()) :: :ok | {:error, Relay.Error.t()}
  def check(body) do
    pointers =
      [{"/to_pointer", body["to_pointer"]}, {"/tenant_pointer", body["tenant_pointer"]}] ++
        for {pointer, index} <- Enum.with_index(body["data_fields"] || []),
            do: {"/data_fields/#{index}", pointer}

    errors =
      for {at, pointer} <- pointers,
          is_binary(pointer),
          not (pointer == "" or String.starts_with?(pointer, "/")),
          do: %{pointer: at, code: "invalid_format", detail: "an RFC 6901 JSON Pointer"}

    if errors == [],
      do: :ok,
      else: {:error, Relay.Error.new(:validation_failed, "invalid pointer", %{errors: errors})}
  end

  defp attrs(body, id) do
    %{
      id: id,
      type: body["type"],
      source: body["source"],
      workflow: body["workflow"],
      to_pointer: body["to_pointer"],
      tenant_pointer: body["tenant_pointer"],
      data_fields: body["data_fields"]
    }
  end

  # API-28
  @doc "Creates a mapping inside the request's transaction; `201`."
  @spec create(map(), <<_::256>>, Relay.Actor.t()) :: answer()
  def create(body, digest, actor) do
    case Relay.Ingest.mapping_create(attrs(body, Relay.Id.generate()), digest, actor) do
      {:created, id, version} -> {:ok, {201, [etag(version)], view(Relay.Ingest.mapping(id))}}
      {:conflict, _id, _version} -> {:error, conflict()}
      {:workflow_not_found, _id, _version} -> {:error, workflow_not_found()}
    end
  end

  # API-28
  @doc "Replaces a mapping inside the request's transaction."
  @spec replace(Relay.Id.t(), map(), pos_integer(), <<_::256>>, Relay.Actor.t()) :: answer()
  def replace(id, body, expected_version, digest, actor) do
    case Relay.Ingest.mapping_replace(attrs(body, id), expected_version, digest, actor) do
      {result, version} when result in [:replaced, :unchanged] ->
        {:ok, {200, [etag(version)], view(Relay.Ingest.mapping(id))}}

      {:conflict, _version} ->
        {:error, conflict()}

      {:version_conflict, _version} ->
        {:error, Relay.Error.new(:precondition_failed, "the mapping changed; read it again")}

      {:workflow_not_found, _version} ->
        {:error, workflow_not_found()}

      {result, _version} when result in [:not_found, :archived] ->
        {:error, not_found()}
    end
  end

  # API-28
  @doc "Archives a mapping inside the request's transaction."
  @spec archive(Relay.Id.t(), pos_integer(), <<_::256>>, Relay.Actor.t()) :: answer()
  def archive(id, expected_version, digest, actor) do
    case Relay.Ingest.mapping_archive(id, expected_version, digest, actor) do
      {:archived, version} -> {:ok, {200, [etag(version)], view(Relay.Ingest.mapping(id))}}
      {:already_archived, _version} -> {:error, Relay.Error.new(:resource_conflict, "archived")}
      {:version_conflict, _version} -> {:error, Relay.Error.new(:precondition_failed, "stale")}
      {:not_found, _version} -> {:error, not_found()}
    end
  end

  # API-56
  @doc "Lists mappings."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    read = fn _status -> Relay.Ingest.mappings(page.cursor, page.limit) end
    position = &{&1["created_at"], &1["id"]}

    with {:ok, rows} <- Relay.Ingest.in_event_scope(scope, read),
         {:ok, body} <- Relay.Api.Page.envelope(rows, page, scope, endpoint, &view/1, position) do
      {:ok, {200, [], body}}
    else
      {:error, %Relay.Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # API-28
  @doc "Reads a mapping."
  @spec get(Relay.Scope.t(), Relay.Id.t()) :: answer()
  def get(scope, id) do
    case Relay.Ingest.in_event_scope(scope, fn _status -> Relay.Ingest.mapping(id) end) do
      {:ok, %{} = mapping} -> {:ok, {200, [etag(mapping["version"])], view(mapping)}}
      _missing -> {:error, not_found()}
    end
  end

  @doc "The error of an unknown mapping."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:event_type_mapping_not_found, "no such mapping")

  defp conflict,
    do: Relay.Error.new(:resource_conflict, "an active mapping exists for this type and source")

  defp workflow_not_found, do: Relay.Error.new(:workflow_not_found, "no workflow has this key")
end
