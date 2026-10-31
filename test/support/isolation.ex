defmodule RelayTest.Isolation do
  @moduledoc """
  The negative isolation test generator (TN-16 (1), API-76, TN-15): every server API operation a router mounts that names a resource in its path is called with one credential against a resource of another scope, and must answer 404 without revealing that the resource exists. The cases come from the router and the contract, so an operation a later change mounts is covered without a new test. A path parameter needs a fixture that creates its resource in a given scope (`fixtures/0`); a mounted operation with a parameter that has none fails the generator, and so does an operation whose body has no entry in `bodies/0`.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Api, RelayTest.Api], exports: []

  alias Relay.Api.Contract

  @parameter ~r/\{([a-z_]+)\}/

  @doc "The server operations with path parameters that `router` mounts, authenticated with a bearer token."
  @spec operations(module()) :: [Contract.operation()]
  def operations(router) do
    mounted = MapSet.new(RelayTest.Api.routes(router))

    for operation <- Contract.operations(),
        operation.family == :server and operation.security == :bearer,
        MapSet.member?(mounted, {operation.method, operation.path}),
        parameters(operation) != [],
        do: operation
  end

  @doc "The path parameters of an operation."
  @spec parameters(Contract.operation()) :: [String.t()]
  def parameters(operation),
    do: Enum.map(Regex.scan(@parameter, operation.path), fn [_, name] -> name end)

  @doc "The fixtures by path parameter: each creates its resource in a scope and returns its external identifier."
  @spec fixtures() :: %{String.t() => (Relay.Scope.t() -> String.t())}
  def fixtures, do: %{"kill_switch_id" => &kill_switch!/1}

  @doc "Request bodies by operation for operations that take one."
  @spec bodies() :: %{String.t() => map()}
  def bodies, do: %{}

  @doc "The path parameters of an operation without a fixture, and whether its body is missing."
  @spec gaps(Contract.operation()) :: [String.t()]
  def gaps(operation) do
    missing = Enum.reject(parameters(operation), &Map.has_key?(fixtures(), &1))
    body? = operation.request != %{} and not Map.has_key?(bodies(), operation.id)
    if body?, do: ["body" | missing], else: missing
  end

  @doc "Creates the resources an operation's path names in `scope` and returns the request path."
  @spec path(Contract.operation(), Relay.Scope.t()) :: String.t()
  def path(operation, scope) do
    ids = Map.new(parameters(operation), &{&1, Map.fetch!(fixtures(), &1).(scope)})
    Regex.replace(@parameter, operation.path, fn _match, name -> Map.fetch!(ids, name) end)
  end

  @doc "Calls an operation at `path` with `token` through `router`."
  @spec call(module(), Contract.operation(), String.t(), String.t()) :: Plug.Conn.t()
  def call(router, operation, path, token) do
    method = operation.method |> String.downcase() |> String.to_existing_atom()
    body = Map.get(bodies(), operation.id)
    key = {"idempotency-key", "isolation-" <> Base.encode16(:crypto.strong_rand_bytes(6))}

    conn =
      if body,
        do: RelayTest.Api.json(method, path, token, body, [key]),
        else: RelayTest.Api.conn(method, path, nil, [{"authorization", "Bearer " <> token}, key])

    RelayTest.Api.call(conn, router)
  end

  @doc "Engages a tenant-scope kill switch in `scope` and returns its identifier."
  @spec kill_switch!(Relay.Scope.t()) :: String.t()
  def kill_switch!(scope) do
    id = Relay.Id.generate()
    expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

    params = [
      id,
      "tenant",
      nil,
      nil,
      "all",
      nil,
      nil,
      nil,
      "off",
      nil,
      nil,
      "isolation",
      "INC-1",
      expires_at,
      nil,
      "operator",
      :crypto.strong_rand_bytes(32),
      "operator",
      "acc_op_1",
      "acc_op_1",
      nil
    ]

    {:ok, [%{"result" => "engaged"}]} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.kill_switch_engage", params)
      end)

    Relay.ExternalId.encode("ksw", id)
  end
end
