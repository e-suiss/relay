defmodule RelayWeb.Api.SmsDestinationController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.SmsDestinations
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # CH-54
  @spec show_policy(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show_policy(conn, _params),
    do: Work.answer(conn, SmsDestinations.get_policy(conn.assigns.scope))

  # CH-54
  @spec replace_policy(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace_policy(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> SmsDestinations.put_policy(scope, body, actor) end)
  end

  # CH-54
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, state} <- SmsDestinations.filters(conn.query_params),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, SmsDestinations.list(scope, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # CH-54
  @spec lift(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lift(conn, %{"sms_destination_stop_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Work.path_id(text, "sds", :sms_destination_stop_not_found) do
      {:ok, id} ->
        reason = body["reason"]
        Work.idempotent(conn, fn _status -> SmsDestinations.lift(scope, id, reason, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end
end
