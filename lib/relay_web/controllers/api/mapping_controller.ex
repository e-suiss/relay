defmodule RelayWeb.Api.MappingController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Mappings
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Mappings.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-28
  # MD-16
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Mappings.check(body) do
      :ok ->
        digest = Work.digest(scope, "event_type_mapping.changed", body["type"])
        Work.idempotent(conn, fn _status -> Mappings.create(body, digest, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"mapping_id" => text}) do
    case Work.path_id(text, "cem", :event_type_mapping_not_found) do
      {:ok, id} -> Work.answer(conn, Mappings.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-28
  # T-59 (7)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"mapping_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- Work.path_id(text, "cem", :event_type_mapping_not_found),
         {:ok, expected} <- Work.if_match(conn, :required),
         :ok <- Mappings.check(body) do
      digest = Work.digest(scope, "event_type_mapping.changed", text)
      Work.idempotent(conn, fn _status -> Mappings.replace(id, body, expected, digest, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-28
  # T-59 (7)
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"mapping_id" => text}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, id} <- Work.path_id(text, "cem", :event_type_mapping_not_found),
         {:ok, expected} <- Work.if_match(conn, :required) do
      digest = Work.digest(scope, "event_type_mapping.changed", text)
      Work.idempotent(conn, fn _status -> Mappings.archive(id, expected, digest, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
