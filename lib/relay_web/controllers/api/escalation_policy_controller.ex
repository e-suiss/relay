defmodule RelayWeb.Api.EscalationPolicyController do
  @moduledoc false

  use RelayWeb, :api_controller

  alias Relay.Api.EscalationPolicies
  alias RelayWeb.Api.Response
  alias RelayWeb.Api.Work

  @key ~r/\A[a-z0-9]+(-[a-z0-9]+)*\z/
  @key_max 100

  # AG-17
  # API-56
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, page} <- Work.page(conn),
         {:ok, state} <- EscalationPolicies.state(conn.query_params) do
      Work.answer(conn, EscalationPolicies.list(scope, state, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-17
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"policy_key" => key}) do
    case key(key) do
      {:ok, key} -> Work.answer(conn, EscalationPolicies.get(conn.assigns.scope, key))
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-17
  # AG-53
  # T-59 (7)
  @spec write(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def write(conn, %{"policy_key" => key}) do
    %{scope: scope, body: body} = conn.assigns
    actor = Work.actor(conn)

    with {:ok, key} <- key(key, EscalationPolicies.invalid_key()),
         {:ok, expected} <- Work.if_match(conn, :optional),
         {:ok, prepared} <- EscalationPolicies.prepare(scope, body) do
      work = fn _status -> EscalationPolicies.put(scope, key, prepared, expected, actor) end
      Work.idempotent(conn, work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-17
  # API-56
  @spec versions(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def versions(conn, %{"policy_key" => key}) do
    %{scope: scope, operation: operation} = conn.assigns

    with {:ok, key} <- key(key),
         {:ok, page} <- Work.page(conn) do
      Work.answer(conn, EscalationPolicies.versions(scope, key, page, operation.endpoint))
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # AG-17
  @spec archive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def archive(conn, %{"policy_key" => key}) do
    scope = conn.assigns.scope
    actor = Work.actor(conn)

    with {:ok, key} <- key(key),
         {:ok, expected} <- Work.if_match(conn, :optional),
         {:ok, names} <- EscalationPolicies.names(scope, key) do
      work = fn _status -> EscalationPolicies.archive(scope, key, names, expected, actor) end
      Work.idempotent(conn, work)
    else
      {:error, error} -> Response.problem(conn, error)
    end
  end

  defp key(key), do: key(key, EscalationPolicies.not_found())

  defp key(key, error) do
    if byte_size(key) <= @key_max and Regex.match?(@key, key),
      do: {:ok, key},
      else: {:error, error}
  end
end
