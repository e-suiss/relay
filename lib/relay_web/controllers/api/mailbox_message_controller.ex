defmodule RelayWeb.Api.MailboxMessageController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.MailboxMessages
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # AG-56
  # AG-59
  # AG-60
  # AG-61
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    traceparent = Work.context(conn).traceparent

    case MailboxMessages.prepare(scope, caller(conn), body, traceparent) do
      {:ok, message} ->
        Work.idempotent(conn, fn _status -> MailboxMessages.send(message) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # AG-59
  # API-56
  @spec requests(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def requests(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} ->
        answer = MailboxMessages.requests(scope, caller(conn), page, operation.endpoint)
        Work.answer(conn, answer)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # AG-56
  # AG-57
  @spec envelope(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def envelope(conn, _params) do
    answer = MailboxMessages.envelope(conn.assigns.scope, caller(conn), conn.query_params)
    Work.answer(conn, answer)
  end

  # AG-61
  @spec block(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def block(conn, _params) do
    caller = caller(conn)
    body = conn.assigns.body
    Work.idempotent(conn, fn _status -> MailboxMessages.block(caller, body) end)
  end

  # AG-61
  @spec report(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def report(conn, _params) do
    caller = caller(conn)
    body = conn.assigns.body
    Work.idempotent(conn, fn _status -> MailboxMessages.report(caller, body) end)
  end

  defp caller(conn) do
    principal = conn.assigns.principal

    %{
      api_client_id: principal.api_client_id,
      agent: principal.agent,
      agent_id: principal.agent_id,
      scopes: principal.scopes
    }
  end
end
