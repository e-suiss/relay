defmodule RelayWeb.Api.InboxController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Inbox
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # IN-29
  # IN-30
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, principal: principal, operation: operation} = conn.assigns
    answer = Inbox.list(scope, principal.subscriber_id, conn.query_params, operation.endpoint)
    Work.answer(conn, answer)
  end

  # IN-5
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"item_id" => text}) do
    %{scope: scope, principal: principal} = conn.assigns

    case Work.path_id(text, "inb", :inbox_item_not_found) do
      {:ok, item_id} -> Work.answer(conn, Inbox.get(scope, principal.subscriber_id, item_id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # IN-18
  # IN-21
  @spec counters(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def counters(conn, _params) do
    %{scope: scope, principal: principal} = conn.assigns
    Work.answer(conn, Inbox.counters(scope, principal.subscriber_id))
  end

  # IN-29
  @spec changes(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def changes(conn, _params) do
    %{scope: scope, principal: principal} = conn.assigns
    Work.answer(conn, Inbox.changes(scope, principal.subscriber_id, conn.query_params))
  end

  # IN-12
  # IN-31
  @spec intent(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def intent(conn, %{"item_id" => text}) do
    %{scope: scope, principal: principal, body: body} = conn.assigns
    subscriber_id = principal.subscriber_id

    with {:ok, item_id} <- Work.path_id(text, "inb", :inbox_item_not_found),
         {:ok, intent} <- Inbox.prepare_intent(body) do
      ref = Relay.ExternalId.encode("sub", subscriber_id) <> " " <> text

      conn
      |> assign(:idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
      |> Work.idempotent(fn _status ->
        Inbox.intent(scope, subscriber_id, item_id, intent, body)
      end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
