defmodule Relay.Api.Routes do
  @moduledoc """
  Named route policies on the server API (WF-13, WF-14, WF-59 (4)): list, create (`201`), read, replace under `If-Match` and archive. A route is unversioned: a replacement applies to every decision made after it, while a notification keeps the tree it was created with. The tree is checked before it is stored (`Relay.Workflow.RouteTree`); a route that an active category names as its default cannot be archived (`route_policy_in_use`).
  """

  alias Relay.Api.Page
  alias Relay.Api.Views

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # WF-13
  @doc "The API view of a route row."
  @spec view(map()) :: map()
  def view(r) do
    %{
      "object" => "route",
      "id" => Views.id("rte", r["id"]),
      "key" => r["key"],
      "name" => r["name"],
      "tree" => r["tree"],
      "state" => r["state"],
      "version" => r["version"],
      "created_at" => r["created_at"],
      "updated_at" => r["updated_at"],
      "archived_at" => r["archived_at"]
    }
  end

  @doc "The ETag header of a route version."
  @spec etag(pos_integer()) :: {String.t(), String.t()}
  def etag(version), do: {"etag", ~s("#{version}")}

  # WF-13
  # WF-59 (4)
  @doc "Creates a route inside the request's transaction; `201` with its view."
  @spec create(Relay.Scope.t(), map(), Relay.Actor.t()) :: answer()
  def create(scope, body, actor) do
    key = body["key"]

    with :ok <- tree(body["tree"]) do
      case Relay.Workflow.create_route(scope, key, body["name"], body["tree"], actor) do
        {:created, _id, version} ->
          location = {"location", "/v1/routes/" <> key}
          {:ok, {201, [etag(version), location], view(Relay.Workflow.route(key))}}

        {:key_conflict, _id, _version} ->
          {:error, Relay.Error.new(:resource_conflict, "a route with this key exists")}

        {:tenant_inactive, _id, _version} ->
          {:error, Relay.Error.new(:auth_tenant_suspended, "the tenant is suspended")}
      end
    end
  end

  # WF-14
  # T-59 (7)
  @doc "Replaces the name and tree of a route under its version inside the request's transaction."
  @spec replace(Relay.Scope.t(), String.t(), map(), pos_integer(), Relay.Actor.t()) :: answer()
  def replace(scope, key, body, expected_version, actor) do
    with :ok <- tree(body["tree"]) do
      scope
      |> Relay.Workflow.replace_route(key, body["name"], body["tree"], expected_version, actor)
      |> replaced(key)
    end
  end

  defp replaced({result, version}, key) when result in [:replaced, :unchanged],
    do: {:ok, {200, [etag(version)], view(Relay.Workflow.route(key))}}

  defp replaced({:version_conflict, _version}, _key),
    do: {:error, Relay.Error.new(:precondition_failed, "the route changed; read it again")}

  defp replaced({:not_found, _version}, _key), do: {:error, not_found()}
  defp replaced({:archived, _version}, _key), do: {:error, archived()}

  # WF-14
  @doc "Archives a route inside the request's transaction; archiving an archived route returns it."
  @spec archive(Relay.Scope.t(), String.t(), Relay.Actor.t()) :: answer()
  def archive(scope, key, actor) do
    case Relay.Workflow.archive_route(scope, key, actor) do
      {result, version} when result in [:archived, :already_archived] ->
        {:ok, {200, [etag(version)], view(Relay.Workflow.route(key))}}

      {:in_use, _version} ->
        {:error, Relay.Error.new(:route_policy_in_use, "a category uses the route by default")}

      {:not_found, _version} ->
        {:error, not_found()}
    end
  end

  # WF-13
  @doc "Reads a route."
  @spec get(Relay.Scope.t(), String.t()) :: answer()
  def get(scope, key) do
    case Relay.Workflow.get_route(scope, key) do
      {:ok, %{} = route} -> {:ok, {200, [etag(route["version"])], view(route)}}
      _missing -> {:error, not_found()}
    end
  end

  # API-56
  @doc "Lists routes."
  @spec list(Relay.Scope.t(), Relay.Api.Pagination.page(), String.t()) :: answer()
  def list(scope, page, endpoint) do
    case Relay.Workflow.list_routes(scope, page.cursor, page.limit) do
      {:ok, rows} ->
        position = &{&1["cursor_at"], &1["id"]}

        with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, position),
             do: {:ok, {200, [], body}}

      {:error, _reason} ->
        {:error, Relay.Error.new(:service_unavailable, "try again")}
    end
  end

  # WF-15
  # WF-59 (4)
  defp tree(tree) do
    case Relay.Workflow.validate_route(tree, pointer: "/tree") do
      :ok ->
        :ok

      {:error, errors} ->
        {:error,
         Relay.Error.new(:validation_failed, "the route tree is invalid", %{errors: errors})}
    end
  end

  @doc "The error of an unknown route key."
  @spec not_found() :: Relay.Error.t()
  def not_found, do: Relay.Error.new(:route_policy_not_found, "no route has this key")

  @doc "The error of a change to an archived route."
  @spec archived() :: Relay.Error.t()
  def archived, do: Relay.Error.new(:route_policy_archived, "the route is archived")
end
