defmodule RelayTest.Api do
  @moduledoc "Helpers for HTTP edge tests: HTTPS requests through a router, tokens, the router-to-contract coverage of the operations, and response validation against the OpenAPI response schemas (API-2)."

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Api, RelayWeb, RelayTest.Api.Verifier],
    exports: []

  import ExUnit.Assertions

  alias Relay.Api.Contract
  alias Relay.Api.ErrorCatalog
  alias Relay.Api.Schema

  @doc "An HTTPS request from a fresh client address; `body` is the raw body."
  @spec conn(atom() | String.t(), String.t(), binary() | nil, [{String.t(), String.t()}]) ::
          Plug.Conn.t()
  def conn(method, path, body \\ nil, headers \\ []) do
    conn = Phoenix.ConnTest.build_conn(method, "https://relay.test" <> path, body)
    conn = %{conn | remote_ip: ip()}

    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_req_header(acc, name, value)
    end)
  end

  @doc "A JSON request with a bearer token."
  @spec json(atom(), String.t(), String.t() | nil, term(), [{String.t(), String.t()}]) ::
          Plug.Conn.t()
  def json(method, path, token, body, headers \\ []) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)
    auth = if token, do: [{"authorization", "Bearer " <> token}], else: []

    conn(method, path, raw, [{"content-type", "application/json"} | auth] ++ headers)
  end

  @doc "A random client address, so per-IP limits of one test never touch another."
  @spec ip() :: :inet.ip_address()
  def ip do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    {10, a, b, c}
  end

  @doc "Runs a request through the endpoint's request id plug and `router`."
  @spec call(Plug.Conn.t(), module()) :: Plug.Conn.t()
  def call(conn, router \\ RelayTest.Api.Router) do
    conn
    |> Plug.RequestId.call(Plug.RequestId.init(http_header: "request-id"))
    |> router.call(router.init([]))
  end

  @doc "A token for a scope; see `RelayTest.Api.Verifier.issue/3`."
  @spec token(Relay.Scope.t(), [String.t()], keyword()) :: String.t()
  defdelegate token(scope, scopes, opts \\ []), to: RelayTest.Api.Verifier, as: :issue

  @doc "The `/v1` routes of a router as `{method, OpenAPI path}`."
  @spec routes(module()) :: [{String.t(), String.t()}]
  def routes(router) do
    for %{verb: verb, path: "/v1" <> _ = path} <- router.__routes__() do
      template = Regex.replace(~r/:([a-z_]+)/, path, "{\\1}")
      {verb |> Atom.to_string() |> String.upcase(), template}
    end
  end

  @doc "How a router covers the server contract: the operations it serves, the operations it lacks, and its routes that are no contract operation."
  @spec coverage(module()) :: %{served: [String.t()], missing: [String.t()], foreign: [tuple()]}
  def coverage(router) do
    operations = Map.new(Contract.operations(), &{{&1.method, &1.path}, &1.id})
    routes = routes(router)
    foreign = Enum.reject(routes, &Map.has_key?(operations, &1))
    served = routes |> Enum.map(&operations[&1]) |> Enum.reject(&is_nil/1)

    %{
      served: Enum.sort(served),
      missing: operations |> Map.values() |> Kernel.--(served) |> Enum.sort(),
      foreign: foreign
    }
  end

  # API-2
  @doc "Asserts that a response follows its operation's contract: a declared status, the headers every response carries, and a body valid against the response schema; a problem names a catalog code whose type resolves on the base URL."
  @spec assert_contract(Plug.Conn.t()) :: Plug.Conn.t()
  def assert_contract(%Plug.Conn{} = conn) do
    operation = conn.assigns.operation
    status = Integer.to_string(conn.status)
    content = operation.responses[status] || operation.responses["default"]

    assert content, "#{operation.id} declares no #{status} response"
    assert [_] = Plug.Conn.get_resp_header(conn, "request-id")
    assert [_] = Plug.Conn.get_resp_header(conn, "relay-version")

    case Plug.Conn.get_resp_header(conn, "content-type") do
      [] ->
        assert conn.resp_body == ""

      [value | _] ->
        media = value |> String.split(";") |> hd() |> String.trim()
        assert Map.has_key?(content, media), "#{operation.id} #{status} is not #{media}"
        body = Jason.decode!(conn.resp_body)
        schema = Schema.response_schema(operation.id, status, media)
        assert schema, "#{operation.id} #{status} #{media} has no schema"
        assert :ok == Schema.validate(Schema.build(schema), body)
        if media == "application/problem+json", do: assert_problem(body)
    end

    conn
  end

  defp assert_problem(%{"code" => code, "type" => type, "status" => status}) do
    assert {:ok, entry} = ErrorCatalog.fetch(code)
    assert entry.status == status
    assert String.ends_with?(type, "/v1/errors/" <> code)
    refute type == "about:blank"
  end
end
