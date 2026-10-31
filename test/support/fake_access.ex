defmodule RelayTest.FakeAccess do
  @moduledoc """
  A fake Access for tests, served to the link's HTTP client as a `Req` plug (`config :relay, Relay.Access, http: [plug: {RelayTest.FakeAccess, []}]`); nothing reaches the network. It publishes a discovery document, an AuthZEN configuration and a key set with one ES256 key (`fake-es256`, tokens) and one Ed25519 key (`fake-ed25519`, webhooks), issues tokens and signs event deliveries with the shared Suiss webhook profile.

  Plug options: `region:` overrides `suiss_region` (the installation region by default), `down: true` answers every request with 503, `keys: :private` publishes a key set with private members.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Access, RelayWeb, RelayTest.Api],
    exports: []

  @behaviour Plug

  import Plug.Conn

  alias RelayWeb.Auth.Access

  @issuer "https://access.test"
  @jobs "SELECT args->>'receipt_id' FROM relay_queue.oban_jobs WHERE worker = 'Relay.Access.EventConsumer' ORDER BY id"
  @es256 :crypto.generate_key(:ecdh, :secp256r1)
  @ed25519 :crypto.generate_key(:eddsa, :ed25519)

  @doc "The fake issuer."
  @spec issuer() :: String.t()
  def issuer, do: @issuer

  @doc "The discovery document for a region."
  @spec discovery(String.t()) :: map()
  def discovery(region) do
    %{
      "issuer" => @issuer,
      "jwks_uri" => @issuer <> "/jwks",
      "token_endpoint" => @issuer <> "/oauth2/token",
      "grant_types_supported" => [
        "client_credentials",
        "urn:ietf:params:oauth:grant-type:token-exchange"
      ],
      "suiss_region" => region,
      "suiss_management_api" => @issuer <> "/management",
      "suiss_event_subscriptions" => @issuer <> "/event-subscriptions"
    }
  end

  @doc "The fake key set."
  @spec jwks() :: map()
  def jwks do
    {<<4, x::binary-32, y::binary-32>>, _private} = @es256
    {ed_public, _ed_private} = @ed25519

    %{
      "keys" => [
        %{
          "kty" => "EC",
          "crv" => "P-256",
          "kid" => "fake-es256",
          "alg" => "ES256",
          "use" => "sig",
          "x" => b64(x),
          "y" => b64(y)
        },
        %{
          "kty" => "OKP",
          "crv" => "Ed25519",
          "kid" => "fake-ed25519",
          "alg" => "EdDSA",
          "use" => "sig",
          "x" => b64(ed_public)
        }
      ]
    }
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    cond do
      Keyword.get(opts, :down, false) ->
        send_resp(conn, 503, "unavailable")

      conn.request_path == "/.well-known/openid-configuration" ->
        json(conn, discovery(Keyword.get_lazy(opts, :region, &installation_region/0)))

      conn.request_path == "/.well-known/authzen-configuration" ->
        json(conn, %{"policy_decision_point" => @issuer})

      conn.request_path == "/jwks" and Keyword.get(opts, :keys) == :private ->
        json(conn, %{"keys" => [Map.put(hd(jwks()["keys"]), "d", b64("secret"))]})

      conn.request_path == "/jwks" ->
        json(conn, jwks())

      true ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  @doc "The installation region."
  @spec installation_region() :: String.t()
  def installation_region do
    %{rows: [[region]]} = Relay.Repo.query!("SELECT region FROM relay.installation", [])
    region
  end

  @doc "Links the node to the fake Access through a real refresh; the test needs the database."
  @spec install!(keyword()) :: :ok
  def install!(plug_opts \\ []) do
    plug_opts = Keyword.put_new_lazy(plug_opts, :region, &installation_region/0)
    {:ok, :ok} = Relay.Access.refresh(http: [plug: {__MODULE__, plug_opts}])
    :ok
  end

  @doc "Registers the trace of an Access client in `scope` and returns its Access client id."
  @spec client!(Relay.Scope.t(), [String.t()], keyword()) :: String.t()
  def client!(scope, scopes, opts \\ []) do
    client_id = Keyword.get(opts, :client_id, "app_" <> random())
    {:ok, actor} = Relay.Actor.new(:access, "access", "access")
    params = [Relay.Id.generate(), client_id, opts[:subtenant_id], scopes, "evt_test", digest()]

    {:ok, [%{"result" => "created"}]} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.api_client_upsert", params ++ Relay.Actor.params(actor))
      end)

    client_id
  end

  @doc "A client credentials token of an Access client for the server API; `claims` override the defaults."
  @spec server_token(String.t(), String.t(), String.t(), map()) :: String.t()
  def server_token(access_tenant_id, client_id, scope, claims \\ %{}) do
    %{
      "sub" => client_id,
      "client_id" => client_id,
      "tenant_id" => access_tenant_id,
      "scope" => scope,
      "aud" => Access.audience(:server)
    }
    |> Map.merge(claims)
    |> token()
  end

  @doc "An end user's Access token for the subscriber token exchange."
  @spec user_token(String.t(), String.t(), String.t(), map()) :: String.t()
  def user_token(access_tenant_id, client_id, sub, claims \\ %{}) do
    %{
      "sub" => sub,
      "client_id" => client_id,
      "tenant_id" => access_tenant_id,
      "aud" => Access.audience(:exchange)
    }
    |> Map.merge(claims)
    |> token()
  end

  @doc "Signs claims with the fake ES256 key; `iss`, `iat`, `nbf` and `exp` default to a token valid for five minutes."
  @spec token(map(), map()) :: String.t()
  def token(claims, header \\ %{}) do
    now = System.system_time(:second)
    defaults = %{"iss" => @issuer, "iat" => now, "nbf" => now, "exp" => now + 300}
    header = Map.merge(%{"alg" => "ES256", "typ" => "at+jwt", "kid" => "fake-es256"}, header)
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(Map.merge(defaults, claims)))
    {_public, private} = @es256
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    input <> "." <> b64(<<r::256, s::256>>)
  end

  @doc "A CloudEvents envelope of an Access event."
  @spec event(String.t(), map(), String.t()) :: map()
  def event(type, data, id \\ "evt_" <> random()) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => @issuer,
      "type" => type,
      "time" => "2026-11-01T00:00:00Z",
      "datacontenttype" => "application/json",
      "data" => data
    }
  end

  @doc "The webhook headers of a delivery of `body` with webhook id `id`; `:timestamp` overrides the time."
  @spec webhook_headers(String.t(), binary(), keyword()) :: [{String.t(), String.t()}]
  def webhook_headers(id, body, opts \\ []) do
    timestamp = Integer.to_string(Keyword.get(opts, :timestamp, System.system_time(:second)))
    {_public, private} = @ed25519
    signed = id <> "." <> timestamp <> "." <> body
    signature = :crypto.sign(:eddsa, :none, signed, [private, :ed25519])

    [
      {"webhook-id", id},
      {"webhook-timestamp", timestamp},
      {"webhook-signature", "v1a," <> Base.encode64(signature)}
    ]
  end

  @doc "Delivers an Access event to `POST /v1/access/events` through the router; `:headers` replaces the signed webhook headers."
  @spec deliver(map(), keyword()) :: Plug.Conn.t()
  def deliver(envelope, opts \\ []) do
    body = Jason.encode!(envelope)
    headers = Keyword.get_lazy(opts, :headers, fn -> webhook_headers(envelope["id"], body) end)
    headers = [{"content-type", "application/cloudevents+json"} | headers]

    :post
    |> RelayTest.Api.conn("/v1/access/events", body, headers)
    |> RelayTest.Api.call(RelayWeb.Router)
  end

  @doc "Applies every queued Access event job, again while new ones appear; returns the receipt identifiers in queue order."
  @spec drain!() :: [Relay.Id.t()]
  def drain! do
    ids = receipt_ids()
    Enum.each(ids, &(:ok = Relay.Access.process_event(&1)))
    if length(receipt_ids()) > length(ids), do: drain!(), else: ids
  end

  defp receipt_ids do
    for [text] <- Relay.Repo.query!(@jobs, []).rows do
      {:ok, id} = Relay.Id.parse(text)
      id
    end
  end

  @doc "Reads an Access event receipt."
  @spec receipt(Relay.Id.t()) :: map()
  def receipt(id) do
    sql = "SELECT * FROM relay_ops.access_event_receipt_read($1)"
    %{columns: columns, rows: [row]} = Relay.Repo.query!(sql, [id])
    columns |> Enum.zip(row) |> Map.new()
  end

  @doc "A random lowercase hex string."
  @spec random() :: String.t()
  def random, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp digest, do: :crypto.strong_rand_bytes(32)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
