defmodule RelayWeb.Api.SubscriberController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.Subscribers
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @external_id ~r/\A[\x21-\x7E]{1,256}\z/

  # API-66
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    %{scope: scope, body: body} = conn.assigns
    write(conn, Subscribers.prepare(scope, body["external_id"], body, :create), nil)
  end

  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    case Work.page(conn) do
      {:ok, page} ->
        %{scope: scope, operation: operation} = conn.assigns
        Work.answer(conn, Subscribers.list(scope, page, operation.endpoint))

      {:error, error} ->
        Response.problem(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"subscriber_id" => external_id}) do
    result =
      with {:ok, external_id} <- external_id(external_id) do
        Work.answer(conn, Subscribers.get(conn.assigns.scope, external_id))
      end

    finish(conn, result)
  end

  # API-66
  # T-59 (7)
  @spec replace(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def replace(conn, %{"subscriber_id" => external_id}) do
    result =
      with {:ok, external_id} <- external_id(external_id),
           {:ok, expected} <- Work.if_match(conn, :optional) do
        fields = Map.new(~w(email phone name locale timezone legal_type attributes), &{&1, nil})
        body = Map.merge(fields, conn.assigns.body)
        prepared = Subscribers.prepare(conn.assigns.scope, external_id, body, :replace)
        write(conn, prepared, expected)
      end

    finish(conn, result)
  end

  # API-66
  # T-59 (7)
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"subscriber_id" => external_id}) do
    result =
      with {:ok, external_id} <- external_id(external_id),
           {:ok, expected} <- Work.if_match(conn, :required) do
        prepared = Subscribers.prepare(conn.assigns.scope, external_id, conn.assigns.body, :patch)
        write(conn, prepared, expected)
      end

    finish(conn, result)
  end

  # API-66
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"subscriber_id" => external_id}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    result =
      with {:ok, external_id} <- external_id(external_id),
           {:ok, plan} <- Subscribers.prepare(scope, external_id, %{}, :require) do
        digest = Work.digest(scope, "subscriber.deletion_requested", external_id)
        Work.idempotent(conn, fn _status -> Subscribers.delete(scope, plan, digest, actor) end)
      end

    finish(conn, result)
  end

  # API-66
  # API-32
  @spec bulk(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def bulk(conn, _params) do
    scope = conn.assigns.scope

    rows =
      for {row, index} <- Enum.with_index(conn.assigns.body["subscribers"]),
          do: {index, row, Subscribers.prepare(scope, row["external_id"], row, :implicit)}

    problem = Work.problem(conn)
    Work.idempotent(conn, fn _status -> Subscribers.bulk(scope, rows, problem) end)
  end

  defp write(conn, {:ok, plan}, expected) do
    scope = conn.assigns.scope
    Work.idempotent(conn, fn _status -> Subscribers.write(scope, plan, expected) end)
  end

  defp write(conn, {:error, error}, _expected), do: Response.problem(conn, error)

  defp external_id(text) do
    if Regex.match?(@external_id, text),
      do: {:ok, text},
      else: {:error, Relay.Error.new(:subscriber_not_found, "no subscriber has this id")}
  end

  defp finish(_conn, %Plug.Conn{} = sent), do: sent
  defp finish(conn, {:error, error}), do: Response.problem(conn, error)
end
