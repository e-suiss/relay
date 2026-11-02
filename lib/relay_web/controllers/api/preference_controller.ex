defmodule RelayWeb.Api.PreferenceController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Preferences
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # PC-57 (5)
  # PC-57 (6)
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"subscriber_id" => external_id}) do
    scope = conn.assigns.scope

    case Preferences.locate(scope, external_id) do
      {:ok, id} -> Work.answer(conn, Preferences.get(scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (5)
  # PC-15
  # PC-6
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"subscriber_id" => external_id}) do
    %{scope: scope, body: body} = conn.assigns
    ref = Work.actor(conn).ref

    case Preferences.locate(scope, external_id) do
      {:ok, id} -> Work.idempotent(conn, &tenant_write(&1, id, body, ref))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp tenant_write(_status, id, body, ref), do: Preferences.update(id, body, :tenant, ref)

  # PC-59 (1)
  # API-56
  @spec consents(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def consents(conn, %{"subscriber_id" => external_id}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- Preferences.locate(scope, external_id),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Preferences.consents(scope, id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # PC-57 (6)
  # API-45
  @spec mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def mine(conn, _params) do
    %{scope: scope, principal: principal} = conn.assigns
    Work.answer(conn, Preferences.get(scope, principal.subscriber_id))
  end

  # PC-57 (5)
  # PC-57 (6)
  # API-45
  @spec update_mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_mine(conn, _params) do
    %{principal: principal, body: body, operation: operation} = conn.assigns
    id = principal.subscriber_id
    ref = Relay.ExternalId.encode("sub", id)

    conn
    |> assign(:idempotency_endpoint, operation.endpoint <> " " <> ref)
    |> Work.idempotent(fn _status -> Preferences.update(id, body, :subscriber, ref) end)
  end
end
