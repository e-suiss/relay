defmodule RelayWeb.Api.WebhookEndpointController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Webhooks
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-2
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, filters} <- Webhooks.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Webhooks.list(scope, filters, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-2
  # WH-45
  # INV-39
  # API-55
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body, api_version: version} = conn.assigns
    actor = Work.actor(conn)

    case Webhooks.prepare_create(scope, body) do
      {:ok, prepared} ->
        work = fn _status -> Webhooks.create(scope, prepared, version, actor) end
        Work.idempotent(conn, work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-2
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"webhook_endpoint_id" => id}) do
    case id(id) do
      {:ok, id} -> Work.answer(conn, Webhooks.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-12
  # WH-48
  # T-59 (7)
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"webhook_endpoint_id" => id}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- id(id),
         {:ok, expected} <- Work.if_match(conn, :optional),
         :ok <- Webhooks.prepare_update(body) do
      Work.idempotent(conn, fn _status -> Webhooks.update(scope, id, body, expected, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-48
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"webhook_endpoint_id" => id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} -> Work.idempotent(conn, fn _status -> Webhooks.archive(scope, id, actor) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-6
  # WH-48
  @spec rotate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rotate(conn, %{"webhook_endpoint_id" => id}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, id} <- id(id),
         {:ok, prepared} <- Webhooks.prepare_rotation(scope, id, body) do
      Work.idempotent(conn, fn _status -> Webhooks.rotate(scope, id, prepared, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-12
  # API-56
  @spec versions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def versions(conn, %{"webhook_endpoint_id" => id}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- id(id),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Webhooks.versions(scope, id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-12
  @spec version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def version(conn, %{"webhook_endpoint_id" => id, "version" => version}) do
    with {:ok, id} <- id(id),
         {:ok, version} <- number(version) do
      Work.answer(conn, Webhooks.get_version(conn.assigns.scope, id, version))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "whe", :webhook_endpoint_not_found)

  defp number(text) do
    case Integer.parse(text) do
      {version, ""} when version >= 1 and version < 1_000_000_000 -> {:ok, version}
      _other -> {:error, Webhooks.not_found()}
    end
  end
end
