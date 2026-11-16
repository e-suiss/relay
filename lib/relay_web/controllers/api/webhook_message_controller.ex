defmodule RelayWeb.Api.WebhookMessageController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.WebhookMessages
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # WH-30 (3)
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, filters} <- WebhookMessages.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookMessages.list(scope, filters, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-30 (3)
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"webhook_message_id" => id}) do
    case id(id) do
      {:ok, id} -> Work.answer(conn, WebhookMessages.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-10
  # API-56
  @spec attempts(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def attempts(conn, %{"webhook_message_id" => id}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- id(id),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, WebhookMessages.attempts(scope, id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-10
  # WH-30
  @spec attempt(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def attempt(conn, %{"webhook_message_id" => id, "webhook_attempt_id" => attempt_id}) do
    with {:ok, id} <- id(id),
         {:ok, attempt_id} <- Work.path_id(attempt_id, "wha", :webhook_attempt_not_found) do
      Work.answer(conn, WebhookMessages.attempt(conn.assigns.scope, id, attempt_id))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WH-31
  # WH-32
  # WH-48
  @spec resend(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resend(conn, %{"webhook_message_id" => id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> WebhookMessages.resend(scope, id, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # WH-31
  # WH-48
  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"webhook_message_id" => id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case id(id) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> WebhookMessages.cancel(scope, id, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp id(text), do: Work.path_id(text, "whm", :webhook_message_not_found)
end
