defmodule RelayTest.PortalIsolation do
  @moduledoc """
  The isolation test generator of the webhook portal (WH-47, TN-16 (1), API-76): every portal operation `RelayWeb.Router` mounts is called with the portal token of one consumer against the endpoint, message and attempt of another consumer, of the same tenant, of another tenant and of the other environment. A mounted portal operation whose path parameter has no fixture here, or whose body is missing, fails the generator's own test, so the suite cannot go quiet when an operation is added.

  A fixture is a consumer with everything a portal operation can name (`world!/1`): its portal token, one endpoint, one test message that failed its only attempt, and that attempt. The engine's test ports must be installed first (`RelayTest.WebhookEngine.install/0`).
  """

  use Boundary,
    top_level?: true,
    deps: [
      Relay,
      Relay.Api,
      Relay.Webhooks,
      RelayWeb,
      RelayTest.Api,
      RelayTest.IngestFixture,
      RelayTest.WebhookEngine
    ],
    exports: []

  import ExUnit.Assertions

  alias Relay.Api.Contract
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.WebhookEngine

  @parameter ~r/\{([a-z_]+)\}/
  @parameters ~w(webhook_endpoint_id webhook_message_id webhook_attempt_id)
  @bodies %{
    "createPortalWebhookEndpoint" => %{
      "url" => "https://hooks.example.com/portal",
      "event_types" => []
    },
    "updatePortalWebhookEndpoint" => %{"description" => "isolation"},
    "rotatePortalWebhookEndpointKey" => %{},
    "sendPortalWebhookEndpointTestEvent" => %{},
    "recoverPortalWebhookEndpoint" => %{"since" => "2026-01-01T00:00:00Z"}
  }

  @doc "The portal operations `router` mounts."
  @spec operations(module()) :: [Contract.operation()]
  def operations(router) do
    mounted = MapSet.new(RelayTest.Api.routes(router))

    for operation <- Contract.operations(),
        operation.security == :portal,
        MapSet.member?(mounted, {operation.method, operation.path}),
        do: operation
  end

  @doc "The path parameters of an operation."
  @spec parameters(Contract.operation()) :: [String.t()]
  def parameters(operation),
    do: Enum.map(Regex.scan(@parameter, operation.path), fn [_, name] -> name end)

  @doc "The path parameters of an operation without a fixture, and whether its body is missing."
  @spec gaps(Contract.operation()) :: [String.t()]
  def gaps(operation) do
    missing = parameters(operation) -- @parameters
    body? = operation.request != %{} and not Map.has_key?(@bodies, operation.id)
    if body?, do: ["body" | missing], else: missing
  end

  @doc "Sends a request with a portal token as Bearer through `RelayWeb.Router`; writes get a fresh idempotency key unless `headers` names one."
  @spec request(atom(), String.t(), String.t() | nil, term(), [{String.t(), String.t()}]) ::
          Plug.Conn.t()
  def request(method, path, token, body \\ nil, headers \\ []) do
    auth = if token, do: [{"authorization", "Bearer " <> token}], else: []

    key =
      if method in [:post, :patch] and not List.keymember?(headers, "idempotency-key", 0),
        do: [F.key()],
        else: []

    {raw, type} =
      case body do
        nil -> {nil, []}
        body -> {Jason.encode!(body), [{"content-type", "application/json"}]}
      end

    method
    |> RelayTest.Api.conn(path, raw, auth ++ type ++ key ++ headers)
    |> RelayTest.Api.call(RelayWeb.Router)
  end

  @doc "Mints a portal token for a consumer of `scope` with an API client credential of the scope."
  @spec token!(Relay.Scope.t(), String.t()) :: String.t()
  def token!(scope, consumer_id) do
    path = "/v1/webhook_consumers/#{consumer_id}/portal_tokens"
    F.body(F.request(:post, path, F.token(scope)), 201)["token"]
  end

  @doc "Creates a consumer in `scope` with a portal token, an endpoint, a test message that failed its one attempt, and that attempt; returns the token and the identifiers by path parameter."
  @spec world!(Relay.Scope.t()) :: %{required(atom() | String.t()) => String.t()}
  def world!(scope) do
    key = "portal-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    created = F.request(:post, "/v1/webhook_consumers", F.token(scope), %{"key" => key})
    consumer = F.body(created, 201)
    token = token!(scope, consumer["id"])

    body = Map.fetch!(@bodies, "createPortalWebhookEndpoint")
    endpoint = F.body(request(:post, "/v1/portal/webhook_endpoints", token, body), 201)
    path = "/v1/portal/webhook_endpoints/#{endpoint["id"]}/test"
    message = F.body(request(:post, path, token), 202)

    {:ok, message_id} = Relay.ExternalId.decode(message["id"], ["whm"])
    :ok = WebhookEngine.answers([WebhookEngine.http(500, [], "down")])
    assert {:ok, {:attempted, _state}} = Relay.Webhooks.attempt(scope, message_id)

    path = "/v1/portal/webhook_messages/#{message["id"]}/attempts"
    assert [attempt] = F.body(request(:get, path, token), 200)["data"]

    %{
      :token => token,
      :consumer_id => consumer["id"],
      :consumer_key => key,
      "webhook_endpoint_id" => endpoint["id"],
      "webhook_message_id" => message["id"],
      "webhook_attempt_id" => attempt["id"]
    }
  end

  @doc "The request path of an operation on the resources of a world."
  @spec path(Contract.operation(), map()) :: String.t()
  def path(operation, world),
    do: Regex.replace(@parameter, operation.path, fn _match, name -> Map.fetch!(world, name) end)

  @doc "Calls an operation at `path` with a portal token."
  @spec call(Contract.operation(), String.t(), String.t()) :: Plug.Conn.t()
  def call(operation, path, token) do
    method = operation.method |> String.downcase() |> String.to_existing_atom()
    request(method, path, token, Map.get(@bodies, operation.id))
  end
end
