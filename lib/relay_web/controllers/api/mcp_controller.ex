defmodule RelayWeb.Api.McpController do
  @moduledoc """
  The Model Context Protocol endpoint (AG-43, E-52): one stateless JSON-RPC request per call. The request has already passed the common rules of a `/v1` operation; here its protocol headers are checked against its body (`Relay.Api.Mcp.request/2`) and its method is answered.

  A tool call runs the controller of the tool's operation, found through the router, on a connection that keeps the response (`RelayWeb.Api.Capture`). Before that the caller's scopes are checked against the operation (`RelayWeb.Auth.permits/2`), the idempotency key is read from the arguments under the operation's rule and the body is validated against the operation's request schema, as the pipeline does for the HTTP request. The operation's own answer, a success or a problem, becomes the tool result; nothing is decided here.
  """

  use RelayWeb, :api_controller

  alias Relay.Api.Contract
  alias Relay.Api.Idempotency
  alias Relay.Api.Mcp
  alias Relay.Api.Schema
  alias Relay.Api.Versions
  alias RelayWeb.Api.Capture
  alias RelayWeb.Api.Response

  @json "application/json"

  # AG-43
  # E-52
  @doc "Answers one JSON-RPC request of the Model Context Protocol; a notification is accepted with no body."
  @spec rpc(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc(conn, _params) do
    case Mcp.request(conn.assigns.body, conn.req_headers) do
      {:ok, %{id: nil}} ->
        send_resp(conn, 202, "")

      {:ok, request} ->
        reply(conn, 200, answer(conn, request))

      {:error, %{status: status, id: id, code: code, message: message, data: data}} ->
        reply(conn, status, Mcp.error(id, code, message, data))
    end
  end

  # AG-44
  # IN-37
  # E-53
  @doc "Appends an AG-UI event to a subscriber's opaque stream; the payload is carried as given."
  @spec publish(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def publish(conn, _params) do
    %{scope: scope, body: body} = conn.assigns

    case Relay.Api.OpaqueStreams.publish(scope, body) do
      {:ok, {status, _headers, answer}} -> Response.json(conn, status, answer)
      {:error, error} -> Response.problem(conn, error)
    end
  end

  # sobelow_skip ["XSS.SendResp"]
  defp reply(conn, status, body) do
    conn
    |> put_resp_header("content-type", @json <> "; charset=utf-8")
    |> send_resp(status, Jason.encode!(body))
  end

  defp answer(_conn, %{method: "server/discover", id: id}), do: Mcp.response(id, Mcp.discover())

  defp answer(conn, %{method: "tools/list", id: id}),
    do: Mcp.response(id, Mcp.list(conn.assigns.principal.scopes))

  defp answer(conn, %{method: "tools/call", id: id, params: params}) do
    case Mcp.tool(Map.get(params, "name")) do
      {:ok, tool} -> Mcp.response(id, call(conn, tool, Map.get(params, "arguments", %{})))
      :error -> Mcp.error(id, -32_602, "Unknown tool")
    end
  end

  # AG-43
  # AG-45
  defp call(conn, tool, arguments) do
    operation = Contract.operation!(tool.operation)

    with :ok <- RelayWeb.Auth.permits(conn.assigns.principal, operation),
         {:ok, parts} <- parts(tool, arguments),
         {:ok, key} <- Idempotency.key(operation.idempotency, parts.key, fn -> :none end),
         {:ok, body} <- body(conn, operation, parts.body),
         {:ok, route} <- route(conn, operation, parts.path) do
      request = %{query: parts.query, raw: raw(parts.body), body: body, key: key}
      answered = run(conn, operation, route, request)
      Mcp.result(answered.status, decoded(answered.resp_body))
    else
      {:error, %Relay.Error{} = error} -> refused(conn, error)
    end
  end

  defp parts(tool, arguments) do
    case Mcp.arguments(tool, arguments) do
      {:ok, parts} -> {:ok, parts}
      {:error, detail} -> {:error, Relay.Error.new(:validation_failed, detail)}
    end
  end

  defp refused(conn, error) do
    {status, _headers, problem} = Response.encode_problem(conn, error)
    Mcp.result(status, decoded(problem))
  end

  defp raw(nil), do: ""
  defp raw(body), do: Jason.encode!(body)

  defp decoded(text) when is_binary(text) and text != "" do
    case Jason.decode(text) do
      {:ok, value} -> value
      {:error, _error} -> %{}
    end
  end

  defp decoded(_empty), do: %{}

  # API-37
  defp body(_conn, %{request: request}, _body) when request == %{}, do: {:ok, nil}
  defp body(_conn, %{request_required: false}, nil), do: {:ok, nil}

  defp body(conn, operation, body) do
    case Schema.validate_request(operation.id, @json, body) do
      :ok -> {:ok, Versions.request(conn.assigns.api_version, operation.id, body)}
      {:error, error} -> {:error, error}
    end
  end

  defp route(conn, operation, path_arguments) do
    path =
      Enum.reduce(path_arguments, operation.path, fn {name, value}, path ->
        String.replace(path, "{" <> name <> "}", URI.encode(value, &URI.char_unreserved?/1))
      end)

    case Phoenix.Router.route_info(RelayWeb.Router, operation.method, path, conn.host) do
      %{plug: plug, plug_opts: action, path_params: params} ->
        {:ok, %{plug: plug, action: action, path: path, path_params: params}}

      :error ->
        {:error, Relay.Error.new(:internal_error, "the operation is not served")}
    end
  end

  defp run(conn, operation, route, request) do
    inner =
      %{
        conn
        | adapter: {Capture, nil},
          method: operation.method,
          request_path: route.path,
          path_info: String.split(route.path, "/", trim: true),
          query_string: URI.encode_query(request.query),
          query_params: request.query,
          path_params: route.path_params,
          params: Map.merge(request.query, route.path_params),
          body_params: %{},
          private:
            conn.private
            |> Map.delete(:before_send)
            |> Map.put(:relay_operation, operation.id),
          state: :unset,
          status: nil,
          resp_body: nil,
          halted: false
      }
      |> assign(:operation, operation)
      |> assign(:media_type, if(request.body, do: @json))
      |> assign(:raw_body, request.raw)
      |> assign(:body, request.body)
      |> assign(:idempotency_key, request.key)

    answered = route.plug.call(inner, route.plug.init(route.action))

    receive do
      {:plug_conn, :sent} -> answered
    after
      0 -> answered
    end
  end
end
