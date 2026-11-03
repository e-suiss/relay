defmodule RelayWeb.Api.BrandController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Brand
  alias RelayWeb.Api.Level
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # TP-36
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Level.subtenant(conn, subtenant_not_found()) do
      {:ok, subtenant_id} -> Work.answer(conn, Brand.get(conn.assigns.scope, subtenant_id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # TP-35
  # TP-36
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, subtenant_id} <- Level.subtenant(conn, subtenant_not_found()),
         {:ok, expected} <- Work.if_match(conn, :optional) do
      Work.idempotent(conn, fn _status ->
        Brand.update(scope, subtenant_id, body, expected, actor)
      end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp subtenant_not_found, do: Relay.Error.new(:subtenant_not_found, "no subtenant has this id")
end
