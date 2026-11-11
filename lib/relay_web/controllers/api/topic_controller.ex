defmodule RelayWeb.Api.TopicController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Topics
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/

  # WF-51
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} -> Work.answer(conn, Topics.list(scope, page, operation.endpoint))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-51
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)
    Work.idempotent(conn, fn _status -> Topics.create(scope, body, actor) end)
  end

  # WF-51
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"topic_key" => key}) do
    case key(key) do
      {:ok, key} -> Work.answer(conn, Topics.get(conn.assigns.scope, key))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-51
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"topic_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    case key(key) do
      {:ok, key} -> Work.idempotent(conn, fn _status -> Topics.archive(scope, key, actor) end)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-51
  # API-56
  @spec subscriptions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscriptions(conn, %{"topic_key" => key}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, key} <- key(key),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, Topics.subscriptions(scope, key, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-51
  # WF-52
  @spec subscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscribe(conn, params), do: change(conn, params, &Topics.subscribe/4)

  # WF-51
  @spec unsubscribe(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unsubscribe(conn, params), do: change(conn, params, &Topics.unsubscribe/4)

  defp change(conn, %{"topic_key" => key}, operation) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, key} <- key(key),
         {:ok, prepared} <- Topics.prepare_change(scope, body) do
      Work.idempotent(conn, fn _status -> operation.(scope, key, prepared, actor) end)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # WF-51
  # API-56
  @spec subscriber(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscriber(conn, %{"subscriber_id" => external_id}) do
    %{scope: scope, operation: operation} = conn.assigns

    case Work.page(conn) do
      {:ok, page} ->
        answer = Topics.subscriber_subscriptions(scope, external_id, page, operation.endpoint)
        Work.answer(conn, answer)

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  defp key(key) do
    if Regex.match?(@key, key), do: {:ok, key}, else: {:error, Topics.not_found()}
  end
end
