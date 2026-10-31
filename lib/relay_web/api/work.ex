defmodule RelayWeb.Api.Work do
  @moduledoc """
  What the API controllers share: the request context of the verified principal (scope, actor, API client, bound sub-tenant, trace context), idempotent work that answers `{status, headers, body}` (`RelayWeb.Api.Response.idempotent/2`), read answers, `If-Match` preconditions (S-66), pagination parameters and prefixed path identifiers. A malformed or foreign path identifier is `404` of its resource (API-76).
  """

  import Plug.Conn

  alias Relay.Api.Pagination
  alias RelayWeb.Api.Response

  @traceparent ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @doc "The request context of the verified principal."
  @spec context(Plug.Conn.t()) :: map()
  def context(conn) do
    principal = conn.assigns.principal

    %{
      scope: conn.assigns.scope,
      actor: actor(conn),
      api_client_id: principal.api_client_id,
      subtenant_id: principal.subtenant_id,
      traceparent: traceparent(conn)
    }
  end

  defp traceparent(conn) do
    case get_req_header(conn, "traceparent") do
      [value | _] -> if Regex.match?(@traceparent, value), do: value
      [] -> nil
    end
  end

  # TN-48
  @doc "The audit actor of the request's API client."
  @spec actor(Plug.Conn.t()) :: Relay.Actor.t()
  def actor(conn) do
    ref = conn.assigns.principal.api_client_id || "api_client"
    {:ok, actor} = Relay.Actor.new(:api_client, ref, ref)
    actor
  end

  @doc "A record digest over an action, the scope and a reference."
  @spec digest(Relay.Scope.t(), String.t(), String.t()) :: <<_::256>>
  def digest(scope, action, ref) do
    environment = Atom.to_string(scope.environment)
    canonical = Relay.Canonical.encode!([action, {:bytes, scope.tenant_id}, environment, ref])
    :crypto.hash(:sha256, canonical)
  end

  # API-10
  # API-13
  # API-14
  @doc "Runs idempotent work and sends its answer; an error rolls the work back and is not stored."
  @spec idempotent(Plug.Conn.t(), (atom() -> answer())) :: Plug.Conn.t()
  def idempotent(conn, work) do
    Response.idempotent(conn, fn status ->
      case work.(status) do
        {:ok, {code, headers, body}} ->
          {code, encoded, bytes} = Response.encode(conn, code, body)
          {:ok, {code, encoded ++ headers, bytes}}

        {:error, %Relay.Error{} = error} ->
          {:error, error}
      end
    end)
  end

  @doc "Sends a read answer."
  @spec answer(Plug.Conn.t(), answer()) :: Plug.Conn.t()
  def answer(conn, {:ok, {status, headers, body}}),
    do: conn |> merge_resp_headers(headers) |> Response.json(status, body)

  def answer(conn, {:error, %Relay.Error{} = error}), do: Response.problem(conn, error)

  # T-59 (7)
  @doc "The version an `If-Match` header names; a missing one is `428 precondition_required`."
  @spec if_match(Plug.Conn.t(), :required | :optional) ::
          {:ok, pos_integer() | nil} | {:error, Relay.Error.t()}
  def if_match(conn, mode) do
    case {Relay.Api.Subscribers.if_match(get_req_header(conn, "if-match")), mode} do
      {{:ok, version}, _mode} ->
        {:ok, version}

      {:missing, :optional} ->
        {:ok, nil}

      {:missing, :required} ->
        {:error, Relay.Error.new(:precondition_required, "send If-Match with the ETag")}

      {:invalid, _mode} ->
        {:error, Relay.Error.new(:precondition_failed, "If-Match names no version")}
    end
  end

  # API-56
  @doc "The pagination parameters of a list request."
  @spec page(Plug.Conn.t()) :: {:ok, Pagination.page()} | {:error, Relay.Error.t()}
  def page(conn) do
    %{scope: scope, operation: operation} = conn.assigns
    Pagination.params(conn.query_params, scope, nil, operation.endpoint)
  end

  # API-9
  # API-76
  @doc "Reads a prefixed path identifier; anything else is the resource's not found error."
  @spec path_id(String.t(), String.t(), atom()) :: {:ok, Relay.Id.t()} | {:error, Relay.Error.t()}
  def path_id(text, prefix, not_found) do
    case Relay.ExternalId.decode(text, [prefix]) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> {:error, Relay.Error.new(not_found, "no such resource")}
    end
  end

  @doc "The problem body renderer of the request, for batch rows."
  @spec problem(Plug.Conn.t()) :: (Relay.Error.t() -> map())
  def problem(conn), do: &Response.problem_body(conn, &1)
end
