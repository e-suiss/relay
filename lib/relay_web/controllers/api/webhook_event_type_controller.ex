defmodule RelayWeb.Api.WebhookEventTypeController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookEventTypes
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-14
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, state} <- WebhookEventTypes.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookEventTypes.list(scope, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-13
  # WH-14
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> WebhookEventTypes.create(scope, body, actor) end)
  end

  # WH-14
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"webhook_event_type_id" => id}) do
    case id(id) do
      {:ok, id} -> Work.answer(conn, WebhookEventTypes.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-14
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"webhook_event_type_id" => id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> WebhookEventTypes.archive(scope, id, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-14
  # API-56
  @spec versions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def versions(conn, %{"webhook_event_type_id" => id}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- id(id),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookEventTypes.versions(scope, id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-14
  @spec add_version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def add_version(conn, %{"webhook_event_type_id" => id}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        work = fn _status -> WebhookEventTypes.add_version(scope, id, body, actor) end
        Work.idempotent(conn, work)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-14
  @spec version(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def version(conn, %{"webhook_event_type_id" => id, "version" => version}) do
    with {:ok, id} <- id(id),
         {:ok, version} <- number(version) do
      Work.answer(conn, WebhookEventTypes.get_version(conn.assigns.scope, id, version))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "wet", :webhook_event_type_not_found)

  defp number(text) do
    case Integer.parse(text) do
      {version, ""} when version >= 1 and version < 1_000_000_000 -> {:ok, version}
      _other -> {:error, WebhookEventTypes.not_found()}
    end
  end
end
