defmodule RelayTest.FakeAccess do
  @moduledoc """
  A fake Access for tests, served to the link's HTTP client as a `Req` plug (`config :relay, Relay.Access, http: [plug: {RelayTest.FakeAccess, []}]`); nothing reaches the network. It publishes an OpenID discovery document, a Suiss configuration, an AuthZEN configuration and a key set with one ES256 key (`fake-es256`, tokens) and one Ed25519 key (`fake-ed25519`, Security Event Tokens), issues tokens and pushes events as Security Event Tokens (E-94).

  Plug options: `region:` overrides `suiss_region` of the Suiss configuration (the installation region by default), `openid:` merges members into the OpenID document, `suiss: :missing` answers the Suiss configuration with 404, `down: true` answers every request with 503, `keys: :private` publishes a key set with private members.
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

  @doc "The OpenID discovery document."
  @spec discovery() :: map()
  def discovery do
    %{
      "issuer" => @issuer,
      "jwks_uri" => @issuer <> "/jwks",
      "token_endpoint" => @issuer <> "/oauth2/token",
      "grant_types_supported" => [
        "client_credentials",
        "urn:ietf:params:oauth:grant-type:token-exchange"
      ]
    }
  end

  @doc "The Suiss configuration for a region, in the shape of Access OP-149 item 3."
  @spec suiss(String.t()) :: map()
  def suiss(region) do
    %{
      "suiss_configuration_version" => 1,
      "issuer" => @issuer,
      "suiss_region" => region,
      "suiss_relay" => "https://relay.test",
      "suiss_management_api" => @issuer <> "/management",
      "suiss_event_subscriptions" => %{
        "ssf_configuration" => @issuer <> "/.well-known/ssf-configuration",
        "webhooks" => "urn:suiss:access:delivery:webhook"
      },
      "suiss_products" => %{},
      "endpoints" => %{}
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
    if Keyword.get(opts, :down, false),
      do: send_resp(conn, 503, "unavailable"),
      else: serve(conn, conn.request_path, opts)
  end

  defp serve(conn, "/.well-known/openid-configuration", opts),
    do: json(conn, Map.merge(discovery(), Keyword.get(opts, :openid, %{})))

  defp serve(conn, "/.well-known/suiss-configuration", opts) do
    if Keyword.get(opts, :suiss) == :missing,
      do: send_resp(conn, 404, ""),
      else: json(conn, suiss(Keyword.get_lazy(opts, :region, &installation_region/0)))
  end

  defp serve(conn, "/.well-known/authzen-configuration", _opts),
    do: json(conn, %{"policy_decision_point" => @issuer})

  defp serve(conn, "/jwks", opts) do
    if Keyword.get(opts, :keys) == :private,
      do: json(conn, %{"keys" => [Map.put(hd(jwks()["keys"]), "d", b64("secret"))]}),
      else: json(conn, jwks())
  end

  defp serve(conn, _path, _opts), do: send_resp(conn, 404, "")

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

  @doc "The claims of a Security Event Token Access pushes for an event of `type` with `data`; `jti` is the event identifier."
  @spec event(String.t(), map(), String.t()) :: map()
  def event(type, data, jti \\ "evt_" <> random()) do
    %{
      "iss" => @issuer,
      "aud" => Relay.Access.client_id(),
      "iat" => System.system_time(:second),
      "jti" => jti,
      "sub_id" => %{"format" => "opaque", "id" => jti},
      "events" => %{("urn:suiss:access:event:" <> type) => data}
    }
  end

  @doc "Signs SET claims with the fake Ed25519 key; `header` overrides members of the JOSE header."
  @spec set(map(), map()) :: String.t()
  def set(claims, header \\ %{}) do
    defaults = %{"alg" => "Ed25519", "typ" => "secevent+jwt", "kid" => "fake-ed25519"}
    input = b64(Jason.encode!(Map.merge(defaults, header))) <> "." <> b64(Jason.encode!(claims))
    {_public, private} = @ed25519
    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [private, :ed25519]))
  end

  @doc "Pushes SET claims, signed with `set/2`, or a ready token to `POST /v1/access/events` through the router; `:content_type` replaces `application/secevent+jwt`."
  @spec deliver(map() | String.t(), keyword()) :: Plug.Conn.t()
  def deliver(claims_or_token, opts \\ [])

  def deliver(claims, opts) when is_map(claims), do: deliver(set(claims), opts)

  def deliver(token, opts) when is_binary(token) do
    headers = [{"content-type", Keyword.get(opts, :content_type, "application/secevent+jwt")}]

    :post
    |> RelayTest.Api.conn("/v1/access/events", token, headers)
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
