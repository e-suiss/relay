defmodule RelayWeb.Api.MigrationController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Migration
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # OP-94
  # OP-52 (2)
  @spec observe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def observe(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    Work.spanning(conn, fn -> Migration.observe(scope, body) end)
  end

  # OP-79
  # OP-94
  @spec coverage(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def coverage(conn, _params), do: Work.answer(conn, Migration.coverage(conn.assigns.scope))

  # OP-79
  @spec differences(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def differences(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Migration.differences(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # OP-52 (3)
  # OP-79
  @spec create_difference(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_difference(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.spanning(conn, fn -> Migration.create_difference(scope, body, actor) end)
  end

  # OP-79
  @spec renew_difference(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def renew_difference(conn, %{"shadow_difference_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Work.path_id(text, "sdf", :shadow_difference_not_found) do
      {:ok, id} ->
        Work.spanning(conn, fn -> Migration.renew_difference(scope, id, body, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # OP-95
  @spec rollout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rollout(conn, _params), do: Work.answer(conn, Migration.rollout(conn.assigns.scope))

  # OP-53
  # OP-95
  @spec replace_rollout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace_rollout(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.spanning(conn, fn -> Migration.replace_rollout(scope, body, actor) end)
  end

  # OP-53
  # OP-95
  @spec stop_rollout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stop_rollout(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.spanning(conn, fn -> Migration.stop_rollout(scope, body["reason"], actor) end)
  end

  # OP-53
  @spec release_rollout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def release_rollout(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.spanning(conn, fn -> Migration.release_rollout(scope, body["reason"], actor) end)
  end

  # OP-54
  # OP-95
  @spec claim(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def claim(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    Work.spanning(conn, fn -> Migration.claim(scope, body) end)
  end

  # OP-52 (1)
  # OP-94
  @spec webhook_shadow(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook_shadow(conn, %{"webhook_endpoint_id" => text}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case Work.path_id(text, "whe", :webhook_endpoint_not_found) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status ->
          Migration.set_webhook_shadow(scope, id, body["shadow"], actor)
        end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  # OP-54
  # OP-95
  @spec displayed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def displayed(conn, _params) do
    %{scope: scope, body: body, principal: principal} = conn.assigns
    Work.spanning(conn, fn -> Migration.displayed(scope, principal.subscriber_id, body) end)
  end
end
