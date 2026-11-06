defmodule RelayWeb.Api.TesterController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.TestSends
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # API-61
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: Work.answer(conn, TestSends.list(conn.assigns.scope, nil))

  # API-61
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case TestSends.prepare_create(scope, body) do
      {:ok, prepared} ->
        Work.idempotent(conn, fn _status -> TestSends.create(scope, prepared, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # API-61
  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, %{"test_recipient_id" => text}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, id} <- Work.path_id(text, "trc", :test_recipient_not_found),
         {:ok, entry} <- TestSends.prepare_entry(scope, id, nil) do
      Work.idempotent(conn, fn _status -> TestSends.remove(scope, entry, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-61
  @spec mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mine(conn, _params) do
    %{scope: scope, principal: principal} = conn.assigns
    Work.answer(conn, TestSends.list(scope, principal.subscriber_id))
  end

  # API-61
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"test_recipient_id" => text}) do
    %{scope: scope, principal: principal} = conn.assigns
    subscriber_id = principal.subscriber_id
    ref = Relay.ExternalId.encode("sub", subscriber_id)
    {:ok, actor} = Relay.Actor.new(:access, ref, ref)

    with {:ok, id} <- Work.path_id(text, "trc", :test_recipient_not_found),
         {:ok, entry} <- TestSends.prepare_entry(scope, id, subscriber_id) do
      conn
      |> assign(:idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
      |> Work.idempotent(fn _status -> TestSends.confirm(scope, entry, subscriber_id, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end
end
