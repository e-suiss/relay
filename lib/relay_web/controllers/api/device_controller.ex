defmodule RelayWeb.Api.DeviceController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Devices
  alias Relay.Api.Preferences
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # API-67
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"subscriber_id" => external_id}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, id} <- Preferences.locate(scope, external_id), {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Devices.list(scope, id, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-67
  # CH-28
  # CH-74
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"subscriber_id" => external_id}) do
    %{scope: scope, body: body} = conn.assigns

    with {:ok, id} <- Preferences.locate(scope, external_id),
         {:ok, plan} <- Devices.prepare(scope, id, body) do
      Work.idempotent(conn, fn _status -> Devices.register(plan) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-67
  # CH-31
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"subscriber_id" => external_id, "device_id" => device_id}) do
    scope = conn.assigns.scope

    with {:ok, id} <- Preferences.locate(scope, external_id),
         {:ok, device} <- Work.path_id(device_id, "dev", :device_not_found) do
      Work.idempotent(conn, fn _status -> Devices.remove({:device, device}, id, :removed) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-67
  # CH-31
  @spec delete_by_token(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_by_token(conn, _params) do
    %{scope: scope, body: body} = conn.assigns

    case Devices.token_digests(scope, body["token"]) do
      {:ok, digests} ->
        ref = {:digests, digests}
        Work.idempotent(conn, fn _status -> Devices.remove(ref, nil, :removed) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # API-46
  # CH-28
  @spec create_mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_mine(conn, _params) do
    %{scope: scope, principal: principal, body: body} = conn.assigns
    id = principal.subscriber_id

    case Devices.prepare(scope, id, body) do
      {:ok, plan} ->
        conn
        |> mine(id)
        |> Work.idempotent(fn _status -> Devices.register(plan) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # API-46
  # CH-31
  @spec delete_mine(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete_mine(conn, %{"device_id" => device_id}) do
    id = conn.assigns.principal.subscriber_id

    case Work.path_id(device_id, "dev", :device_not_found) do
      {:ok, device} ->
        conn
        |> mine(id)
        |> Work.idempotent(fn _status -> Devices.remove({:device, device}, id, :logout) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp mine(conn, id) do
    ref = Relay.ExternalId.encode("sub", id)
    assign(conn, :idempotency_endpoint, conn.assigns.operation.endpoint <> " " <> ref)
  end
end
