defmodule Relay.Api.Workflows do
  @moduledoc """
  The workflow management operations (API-69, WF-5, WF-6): list, create with a first draft (`201`), read, replace the draft under `If-Match`, request a publication (`202`, through the publication gate), list and read published versions, and promote an old version as a new one (`202`). A published version never changes (INV-48).
  """

  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # WF-5
  @doc "The API view of a workflow with its draft and last publication."
  @spec view(map()) :: map()
  def view(w) do
    %{
      "object" => "workflow",
      "id" => Views.id("wfl", w["id"]),
      "key" => w["key"],
      "name" => w["name"],
      "managed_by" => w["managed_by"],
      "published_version" => w["published_version_no"],
      "draft" => w["draft"] && w["draft"]["definition"],
      "draft_version_id" => w["draft"] && Views.id("wfv", w["draft"]["id"]),
      "last_publication" => publication(w["publication"]),
      "state" => w["state"],
      "version" => w["version"],
      "created_at" => w["created_at"],
      "updated_at" => w["updated_at"]
    }
  end

  defp publication(nil), do: nil

  defp publication(v) do
    %{
      "status" => v["state"],
      "version" => v["version_no"],
      "requested_at" => v["requested_at"],
      "finished_at" => finished(v)
    }
    |> Views.put_unless_nil("errors", v["publication_errors"])
  end

  defp finished(%{"state" => "published", "published_at" => at}), do: at
  defp finished(%{"state" => "rejected", "updated_at" => at}), do: at
  defp finished(_pending), do: nil

  # WF-6
  @doc "The API view of a published version."
  @spec version_view(String.t(), map()) :: map()
  def version_view(key, v) do
    %{
      "object" => "workflow_version",
      "id" => Views.id("wfv", v["id"]),
      "workflow_key" => key,
      "version" => v["version_no"],
      "definition" => v["definition"],
      "definition_digest" => Base.encode16(v["definition_digest"], case: :lower),
      "promoted_from" => v["promoted_from_version_no"],
      "published_at" => v["published_at"]
    }
    |> Views.put_unless_nil("published_by", v["published_by_ref"])
  end

  @doc "The ETag header of a workflow version number."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # WF-1
  # WF-5
  @doc "Creates a workflow with its first draft inside the request's transaction."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, body, actor) do
    case Relay.Workflow.create(scope, body["key"], body["definition"], actor) do
      {:ok, {:created, _id, version}} ->
        {:ok, {201, [etag(version)], view(Relay.Workflow.view(body["key"]))}}

      {:ok, {:key_conflict, _id, _version}} ->
        {:error, Relay.Error.new(:resource_conflict, "a workflow with this key exists")}

      {:ok, {:tenant_inactive, _id, _version}} ->
        {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
    end
  end

  # WF-5
  @doc "Replaces the draft of a workflow inside the request's transaction."
  @spec replace(Relay.Scope.t(), String.t(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def replace(scope, key, body, expected_version, actor) do
    case Relay.Workflow.replace_draft(scope, key, body["definition"], expected_version, actor) do
      {:ok, {result, version}} when result in [:replaced, :unchanged] ->
        {:ok, {200, [etag(version)], view(Relay.Workflow.view(key))}}

      {:ok, {:version_conflict, _version}} ->
        {:error, precondition_failed()}

      {:ok, {:not_found, _version}} ->
        {:error, workflow_not_found()}
    end
  end

  # WF-6
  @doc "Sends the draft to the publication gate inside the request's transaction; `202` with the pending publication."
  @spec publish(Relay.Scope.t(), String.t(), pos_integer(), String.t() | nil, Relay.Actor.t()) ::
          answer()
  def publish(scope, key, expected_version, note, actor) do
    case Relay.Workflow.request_publication(scope, key, expected_version, note, actor) do
      {:ok, {:pending, _version_id}} -> accepted(key)
      {:ok, {:version_conflict, _id}} -> {:error, precondition_failed()}
      {:ok, {:not_found, _id}} -> {:error, workflow_not_found()}
      {:ok, {:no_draft, _id}} -> {:error, conflict("the workflow has no draft to publish")}
      {:ok, {:already_pending, _id}} -> {:error, conflict("a publication is already pending")}
    end
  end

  # WF-6
  @doc "Publishes an old version again as a new version inside the request's transaction; `202`."
  @spec promote(Relay.Scope.t(), String.t(), pos_integer(), Relay.Actor.t()) :: answer()
  def promote(scope, key, version_no, actor) do
    case Relay.Workflow.promote(scope, key, version_no, actor) do
      {:ok, {:pending, _version_id}} -> accepted(key)
      {:ok, {:version_not_found, _id}} -> {:error, version_not_found()}
      {:ok, {:not_found, _id}} -> {:error, workflow_not_found()}
      {:ok, {:already_pending, _id}} -> {:error, conflict("a publication is already pending")}
    end
  end

  defp accepted(key) do
    publication = Relay.Workflow.view(key)["publication"]

    {:ok,
     {202, [],
      %{
        "object" => "workflow_publication",
        "workflow_key" => key,
        "publication" => publication(publication)
      }}}
  end

  # API-56
  @doc "Lists workflows."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    case Relay.Workflow.list(scope, page.cursor, page.limit) do
      {:ok, rows} -> envelope(rows, page, scope, endpoint, &view/1)
      {:error, _reason} -> {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # WF-5
  @doc "Reads a workflow."
  @spec get(Relay.Scope.t(), String.t()) :: answer()
  def get(scope, key) do
    case Relay.Workflow.get(scope, key) do
      {:ok, %{} = workflow} -> {:ok, {200, [etag(workflow["version"])], view(workflow)}}
      _missing -> {:error, workflow_not_found()}
    end
  end

  # API-56
  # WF-6
  @doc "Lists the published versions of a workflow."
  @spec versions(Relay.Scope.t(), String.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def versions(scope, key, page, endpoint) do
    case Relay.Workflow.list_versions(scope, key, page.cursor, page.limit) do
      {:ok, rows} when is_list(rows) ->
        envelope(rows, page, scope, endpoint, &version_view(key, &1))

      _missing ->
        {:error, workflow_not_found()}
    end
  end

  # WF-6
  @doc "Reads a published version."
  @spec version(Relay.Scope.t(), String.t(), pos_integer()) :: answer()
  def version(scope, key, number) do
    case Relay.Workflow.get_version(scope, key, number) do
      {:ok, %{} = version} -> {:ok, {200, [], version_view(key, version)}}
      {:ok, :workflow_not_found} -> {:error, workflow_not_found()}
      _missing -> {:error, version_not_found()}
    end
  end

  defp envelope(rows, page, scope, endpoint, view) do
    position = &{&1["cursor_at"], &1["id"]}

    with {:ok, body} <- Relay.Api.Page.envelope(rows, page, scope, endpoint, view, position),
         do: {:ok, {200, [], body}}
  end

  @doc "The error of an unknown workflow key."
  @spec workflow_not_found() :: Relay.Error.t()
  def workflow_not_found, do: Relay.Error.new(:workflow_not_found, "no workflow has this key")

  @doc "The error of an unknown published version."
  @spec version_not_found() :: Relay.Error.t()
  def version_not_found,
    do: Relay.Error.new(:workflow_version_not_found, "the workflow has no such published version")

  defp precondition_failed,
    do: Relay.Error.new(:precondition_failed, "the workflow changed; read it again")

  defp conflict(message), do: Relay.Error.new(:resource_conflict, message)
end
