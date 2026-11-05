defmodule RelayWeb.Api.MessagingController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Messaging
  alias Relay.Api.Preferences
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # CH-62
  # C-22
  @spec put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put(conn, %{"subscriber_id" => external_id, "channel" => channel}) do
    %{scope: scope, body: body} = conn.assigns

    with {:ok, id} <- Preferences.locate(scope, external_id),
         {:ok, plan} <- Messaging.prepare_target(scope, id, channel, body) do
      Work.idempotent(conn, fn _status -> Messaging.write_target(plan) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-62
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"subscriber_id" => external_id, "channel" => channel}) do
    case Preferences.locate(conn.assigns.scope, external_id) do
      {:ok, id} -> Work.idempotent(conn, fn _status -> Messaging.remove_target(id, channel) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-62
  @spec install(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def install(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    answer = Messaging.install(scope, body, Response.base_url(), Work.actor(conn))

    case answer do
      {:ok, _response} -> Work.idempotent(conn, fn _status -> answer end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-62
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, _params), do: Work.answer(conn, Messaging.callback(conn.query_params))

  # CH-4
  @spec adapters(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def adapters(conn, _params), do: Work.answer(conn, Messaging.adapters(conn.assigns.scope))
end
