defmodule RelayWeb.Api.WebhookPortalController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookCatalog
  alias Relay.Api.WebhookPortal, as: Portal
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work
  alias RelayWeb.Auth.Access

  # WH-47
  @spec token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def token(conn, %{"webhook_consumer_id" => id}) do
    scope = conn.assigns.scope

    with {:ok, id} <- Work.path_id(id, "whc", :webhook_consumer_not_found),
         {:ok, minted} <- Portal.prepare_token(scope, id, Access.portal_audiences()) do
      Work.idempotent(conn, fn _status -> {:ok, minted} end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-14
  # WH-53
  # API-56
  @spec catalog(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def catalog(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, WebhookCatalog.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-46
  # API-56
  @spec event_types(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def event_types(conn, _params) do
    endpoint = conn.assigns.operation.endpoint

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Portal.event_types(portal(conn), page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-47
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    endpoint = conn.assigns.operation.endpoint

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Portal.endpoints(portal(conn), page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-46
  # WH-48
  # WH-52
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{body: body, api_version: version} = conn.assigns
    portal = portal(conn)
    actor = Portal.actor(portal)

    case Portal.prepare_create(portal, body) do
      {:ok, prepared} ->
        work = fn _status -> Portal.create(portal, prepared, version, actor) end
        conn |> keyed(portal) |> Work.idempotent(work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-47
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"webhook_endpoint_id" => id}) do
    case endpoint_id(id) do
      {:ok, id} -> Work.answer(conn, Portal.get(portal(conn), id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-46
  # WH-48
  # T-59 (7)
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"webhook_endpoint_id" => id}) do
    portal = portal(conn)
    actor = Portal.actor(portal)

    with {:ok, id} <- endpoint_id(id),
         {:ok, expected} <- Work.if_match(conn, :optional),
         {:ok, patch} <- Portal.prepare_update(portal, id, conn.assigns.body) do
      work = fn _status -> Portal.update(portal, id, patch, expected, actor) end
      conn |> keyed(portal) |> Work.idempotent(work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-46
  # WH-48
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"webhook_endpoint_id" => id}) do
    portal = portal(conn)
    actor = Portal.actor(portal)

    case endpoint_id(id) do
      {:ok, id} ->
        work = fn _status -> Portal.archive(portal, id, actor) end
        conn |> keyed(portal) |> Work.idempotent(work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-6
  # WH-48
  @spec rotate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rotate(conn, %{"webhook_endpoint_id" => id}) do
    portal = portal(conn)
    actor = Portal.actor(portal)

    with {:ok, id} <- endpoint_id(id),
         {:ok, prepared} <- Portal.prepare_rotation(portal, id, conn.assigns.body) do
      work = fn _status -> Portal.rotate(portal, id, prepared, actor) end
      conn |> keyed(portal) |> Work.idempotent(work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-39
  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, %{"webhook_endpoint_id" => id}) do
    case endpoint_id(id) do
      {:ok, id} -> Work.answer(conn, Portal.health(portal(conn), id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-45 (3)
  @spec test(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def test(conn, %{"webhook_endpoint_id" => id}) do
    portal = portal(conn)
    body = conn.assigns.body

    case endpoint_id(id) do
      {:ok, id} ->
        work = fn _status -> Portal.test(portal, id, body) end
        conn |> keyed(portal) |> Work.idempotent(work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-31
  # WH-48
  @spec recover(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def recover(conn, %{"webhook_endpoint_id" => id}) do
    portal = portal(conn)
    actor = Portal.actor(portal)
    body = conn.assigns.body

    case endpoint_id(id) do
      {:ok, id} ->
        work = fn _status -> Portal.recover(portal, id, body, actor) end
        conn |> keyed(portal) |> Work.idempotent(work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-30 (2)
  # API-56
  @spec missed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def missed(conn, %{"webhook_endpoint_id" => id}) do
    endpoint = conn.assigns.operation.endpoint

    with {:ok, id} <- endpoint_id(id),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Portal.missed(portal(conn), id, conn.query_params, page, endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-30 (3)
  # WH-47
  # API-56
  @spec messages(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def messages(conn, _params) do
    endpoint = conn.assigns.operation.endpoint

    case Work.page(conn) do
      {:ok, page} ->
        Work.answer(conn, Portal.messages(portal(conn), conn.query_params, page, endpoint))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-47
  @spec message(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def message(conn, %{"webhook_message_id" => id}) do
    case message_id(id) do
      {:ok, id} -> Work.answer(conn, Portal.message(portal(conn), id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-10
  # API-56
  @spec attempts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def attempts(conn, %{"webhook_message_id" => id}) do
    endpoint = conn.assigns.operation.endpoint

    with {:ok, id} <- message_id(id),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Portal.attempts(portal(conn), id, page, endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-10
  @spec attempt(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def attempt(conn, %{"webhook_message_id" => message_id, "webhook_attempt_id" => id}) do
    with {:ok, message_id} <- message_id(message_id),
         {:ok, id} <- Work.path_id(id, "wha", :webhook_attempt_not_found) do
      Work.answer(conn, Portal.attempt(portal(conn), message_id, id))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-32
  # WH-48
  @spec resend(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resend(conn, %{"webhook_message_id" => id}) do
    portal = portal(conn)
    actor = Portal.actor(portal)

    case message_id(id) do
      {:ok, id} ->
        work = fn _status -> Portal.resend(portal, id, actor) end
        conn |> keyed(portal) |> Work.idempotent(work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-47
  defp portal(conn),
    do: %{scope: conn.assigns.scope, consumer_id: conn.assigns.principal.consumer_id}

  # WH-47
  # API-10
  defp keyed(conn, %{consumer_id: consumer_id}) do
    ref = Relay.ExternalId.encode("whc", consumer_id)
    assign(conn, :idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
  end

  defp endpoint_id(text), do: Work.path_id(text, "whe", :webhook_endpoint_not_found)
  defp message_id(text), do: Work.path_id(text, "whm", :webhook_message_not_found)
end
