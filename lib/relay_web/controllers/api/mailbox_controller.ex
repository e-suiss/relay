defmodule RelayWeb.Api.MailboxController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Mailbox
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # AG-20
  # AG-64
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params), do: Work.answer(conn, Mailbox.get(conn.assigns.scope, caller(conn)))

  # AG-20
  # AG-22
  # AG-53
  @spec lease(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lease(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    caller = caller(conn)
    Work.spanning(conn, fn -> Mailbox.lease(scope, caller, body) end)
  end

  # AG-20
  @spec ack(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ack(conn, _params) do
    caller = caller(conn)
    body = conn.assigns.body
    Work.idempotent(conn, fn _status -> Mailbox.ack(caller, body) end)
  end

  # AG-20
  # AG-24
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    answer = Mailbox.read(conn.assigns.scope, caller(conn), conn.query_params)
    Work.answer(conn, answer)
  end

  # AG-21
  # AG-40
  @spec record(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def record(conn, %{"record_id" => id}) do
    case Work.path_id(id, "mbr", :mailbox_record_not_found) do
      {:ok, id} ->
        answer = Mailbox.record(conn.assigns.scope, caller(conn), id, conn.query_params)
        Work.answer(conn, answer)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # AG-22
  # API-56
  @spec dead_letters(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def dead_letters(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} ->
        answer =
          Mailbox.dead_letters(scope, caller(conn), conn.query_params, page, operation.endpoint)

        Work.answer(conn, answer)

      {:error, error} ->
        Response.problem(conn, error)
    end
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
