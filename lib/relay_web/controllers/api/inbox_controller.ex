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
  # IN-3
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"item_id" => text}) do
    %{scope: scope, principal: principal} = conn.assigns

    case target(text) do
      {:ok, target} -> Work.answer(conn, Inbox.get(scope, principal.subscriber_id, target))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp target("ann_" <> _rest = text) do
    case Work.path_id(text, "ann", :inbox_item_not_found) do
      {:ok, id} -> {:ok, {:announcement, id}}
      {:error, error} -> {:error, error}
    end
  end

  defp target(text), do: Work.path_id(text, "inb", :inbox_item_not_found)

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

    with {:ok, item_id} <- target(text),
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

  # IN-50
  # IN-14
  # IN-31
  @spec read_all(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def read_all(conn, _params) do
    %{scope: scope, principal: principal, body: body} = conn.assigns
    subscriber_id = principal.subscriber_id
    ref = Relay.ExternalId.encode("sub", subscriber_id)

    conn
    |> assign(:idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
    |> Work.idempotent(fn _status -> Inbox.read_all(scope, subscriber_id, body || %{}) end)
  end

  # IN-14
  # IN-31
  @spec start_bulk(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start_bulk(conn, _params) do
    %{scope: scope, principal: principal, body: body} = conn.assigns
    subscriber_id = principal.subscriber_id
    ref = Relay.ExternalId.encode("sub", subscriber_id)

    conn
    |> assign(:idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
    |> Work.idempotent(fn _status -> Inbox.start_bulk(scope, subscriber_id, body || %{}) end)
  end

  # IN-14
  @spec bulk(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bulk(conn, %{"bulk_id" => text}) do
    %{scope: scope, principal: principal} = conn.assigns

    case Work.path_id(text, "ibk", :inbox_bulk_operation_not_found) do
      {:ok, id} -> Work.answer(conn, Inbox.bulk(scope, principal.subscriber_id, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # IN-21
  @spec inconsistency(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def inconsistency(conn, _params) do
    %{scope: scope, principal: principal} = conn.assigns
    Work.answer(conn, Inbox.report_inconsistency(scope, principal.subscriber_id))
  end
end
