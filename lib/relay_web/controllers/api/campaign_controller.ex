defmodule RelayWeb.Api.CampaignController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Campaigns
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  # API-35
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: %{endpoint: endpoint}} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Campaigns.list(scope, page, endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-35
  # WF-34
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    scope = conn.assigns.scope

    case Campaigns.plan_create(Work.context(conn), conn.assigns.body) do
      {:ok, plan} -> Work.idempotent(conn, fn _status -> Campaigns.create(scope, plan) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # API-35
  # X-14
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    case path_id(params) do
      {:ok, id} -> Work.answer(conn, Campaigns.get(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-52
  @spec recipients(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def recipients(conn, params) do
    with {:ok, id} <- path_id(params),
         {:ok, bidxs} <- Campaigns.plan_recipients(conn.assigns.scope, conn.assigns.body) do
      Work.idempotent(conn, fn _status -> Campaigns.add_recipients(id, bidxs) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-44
  # WF-52
  @spec prepare(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def prepare(conn, params) do
    scope = conn.assigns.scope

    with {:ok, id} <- path_id(params),
         {:ok, plan} <- Campaigns.plan_prepare(scope, id) do
      Work.idempotent(conn, fn _status -> Campaigns.prepare(scope, plan) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-62
  @spec samples(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def samples(conn, params) do
    case path_id(params) do
      {:ok, id} -> Work.answer(conn, Campaigns.samples(conn.assigns.scope, id))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-62
  @spec approve_samples(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def approve_samples(conn, params) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, id} <- path_id(params),
         {:ok, digest} <- Campaigns.plan_approve(scope, id, conn.assigns.body) do
      Work.idempotent(conn, fn _status -> Campaigns.approve_samples(scope, id, digest, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-44
  # WF-62
  @spec trigger(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def trigger(conn, params) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, id} <- path_id(params),
         {:ok, digest} <- Campaigns.plan_trigger(scope, id) do
      Work.idempotent(conn, fn _status -> Campaigns.trigger(scope, id, digest, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-44
  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    case path_id(params) do
      {:ok, id} ->
        Work.idempotent(conn, fn _status -> Campaigns.cancel(scope, id, body, actor) end)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp path_id(params) do
    text = Map.get(params, "campaign_id", "")
    Work.path_id(text, Campaigns.prefix(), :campaign_not_found)
  end
end
