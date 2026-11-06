defmodule RelayTest.FakeAccess do
  @moduledoc """
  A fake Access for tests, served to the link's HTTP client as a `Req` plug (`config :relay, Relay.Access, http: [plug: {RelayTest.FakeAccess, []}]`); nothing reaches the network. It publishes an OpenID discovery document, a Suiss configuration, an AuthZEN configuration and a key set with one ES256 key (`fake-es256`, tokens) and one Ed25519 key (`fake-ed25519`, Security Event Tokens), issues tokens and pushes events as Security Event Tokens (E-94).

  Every known tenant has two realms, `a` and `b` (`realm_issuer/2`), each with its own discovery document and ES256 key; the tenant snapshot names them, and a tenant whose id starts with `tnt_unknown` is not known (E-96). Relay's own calls are checked as Access checks them (E-98): the token endpoint takes only Relay's `private_key_jwt` client assertion signed by the key-store key `access-dpop`, and it, the tenant snapshot and the AuthZEN evaluation take only a DPoP proof carrying the fake's nonce, answering `use_dpop_nonce` with a `DPoP-Nonce` otherwise; resources take only the DPoP token the fake issued, bound to the proof key. The calling test process receives `{:fake_access, :token, jkt, grant_type}`, `{:fake_access, :nonce, :token | :resource}`, `{:fake_access, :snapshot, tenant}`, `{:fake_access, :realm_keys, slug}` and `{:fake_access, :evaluation, body}`.

  Plug options: `region:` overrides `suiss_region` of the Suiss configuration (the installation region by default), `openid:` merges members into the OpenID document, `suiss: :missing` answers the Suiss configuration with 404, `down: true` answers every request with 503, `keys: :private` publishes a key set with private members.
  """

  use Boundary,
    top_level?: true,
    deps: [Relay, Relay.Access, RelayWeb, RelayTest.Api, RelayTest.Dpop],
    exports: []

  @behaviour Plug

  import Plug.Conn

  @issuer "https://access.test"
  @jobs "SELECT args->>'receipt_id' FROM relay_queue.oban_jobs WHERE worker = 'Relay.Access.EventConsumer' ORDER BY id"
  @es256 :crypto.generate_key(:ecdh, :secp256r1)
  @ed25519 :crypto.generate_key(:eddsa, :ed25519)
  @realms ["a", "b"]
  @realm_keys %{
    "a" => :crypto.generate_key(:ecdh, :secp256r1),
    "b" => :crypto.generate_key(:ecdh, :secp256r1)
  }
  @nonce "fake-access-nonce"
  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

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
      "endpoints" => %{"tenant_snapshot" => @issuer <> "/access/v1/tenants/{tenant}/snapshot"}
    }
  end

  # E-96
  @doc "The issuer of one of the two realms (`\"a\"` or `\"b\"`) every known tenant has: a path issuer under the fake issuer."
  @spec realm_issuer(String.t(), String.t()) :: String.t()
  def realm_issuer(access_tenant_id, realm) when realm in @realms,
    do: @issuer <> "/realms/" <> access_tenant_id <> "-" <> realm

  # E-96
  @doc "The snapshot of a known tenant, in the shape of Access OP-149 item 4: its two realms."
  @spec snapshot(String.t()) :: map()
  def snapshot(access_tenant_id) do
    realms =
      for realm <- @realms do
        %{
          "id" => "00000000-0000-4000-8000-00000000000" <> realm,
          "issuer" => realm_issuer(access_tenant_id, realm),
          "slug" => access_tenant_id <> "-" <> realm
        }
      end

    %{
      "tenant" => access_tenant_id,
      "organizations" => [],
      "realms" => realms,
      "region" => installation_region(),
      "status" => "active",
      "version" => "1",
      "retention" => %{}
    }
  end

  # E-96
  @doc "A DPoP-bound service token of a tenant API client issued by realm `realm` of its tenant (`iss` the realm, a pairwise `sub`), signed by the key of realm `signer` (the same realm by default); `claims` override the defaults."
  @spec realm_token(String.t(), String.t(), String.t(), map(), String.t() | nil) :: String.t()
  def realm_token(access_tenant_id, client_id, realm, claims \\ %{}, signer \\ nil) do
    signer = signer || realm

    %{
      "iss" => realm_issuer(access_tenant_id, realm),
      "sub" => "pairwise-" <> random(),
      "client_id" => client_id,
      "access_tenant" => access_tenant_id
    }
    |> Map.merge(claims)
    |> token(%{"kid" => "realm-" <> signer}, Map.fetch!(@realm_keys, signer))
  end

  # E-98
  @doc "The DPoP nonce the fake asks for at its token endpoint and resources."
  @spec nonce() :: String.t()
  def nonce, do: @nonce

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

  defp serve(conn, "/oauth2/token", _opts), do: token_endpoint(conn)

  defp serve(conn, "/access/v1/evaluation", _opts), do: authorized(conn, &evaluation/1)

  defp serve(conn, "/access/v1/tenants/" <> rest, _opts) do
    case String.split(rest, "/") do
      [tenant, "snapshot"] -> authorized(conn, &tenant_snapshot(&1, tenant))
      _other -> send_resp(conn, 404, "")
    end
  end

  defp serve(conn, "/realms/" <> rest, _opts) do
    case String.split(rest, "/") do
      [slug, ".well-known", "openid-configuration"] -> json(conn, realm_discovery(slug))
      [slug, "jwks"] -> realm_jwks(conn, slug)
      _other -> send_resp(conn, 404, "")
    end
  end

  defp serve(conn, _path, _opts), do: send_resp(conn, 404, "")

  # E-98
  defp token_endpoint(conn) do
    {:ok, body, conn} = read_body(conn)
    form = URI.decode_query(body)

    case {client_assertion?(form), proved(conn, nil)} do
      {false, _proved} ->
        oauth_error(conn, 401, "invalid_client")

      {true, {:ok, jkt, @nonce}} ->
        send(self(), {:fake_access, :token, jkt, form["grant_type"]})
        token = "relay." <> jkt <> "." <> random()
        json(conn, %{"access_token" => token, "token_type" => "DPoP", "expires_in" => 300})

      {true, {:ok, _jkt, _nonce}} ->
        send(self(), {:fake_access, :nonce, :token})
        conn |> put_resp_header("dpop-nonce", @nonce) |> oauth_error(400, "use_dpop_nonce")

      {true, :error} ->
        oauth_error(conn, 400, "invalid_dpop_proof")
    end
  end

  defp client_assertion?(%{
         "client_assertion_type" => @assertion_type,
         "client_assertion" => assertion,
         "client_id" => client_id
       }) do
    expected = Relay.Access.client_id()
    {:ok, point} = Relay.Keys.public_key(:es256, "access-dpop")

    case parts(assertion) do
      {:ok, %{"alg" => "ES256", "typ" => "JWT"}, claims, input, sig} ->
        named = [client_id, claims["iss"], claims["sub"]] == [expected, expected, expected]
        named and claims["aud"] == @issuer and es256?(input, sig, point)

      _other ->
        false
    end
  end

  defp client_assertion?(_form), do: false

  defp authorized(conn, answer) do
    with ["DPoP " <> token] <- get_req_header(conn, "authorization"),
         ["relay", jkt, _random] <- String.split(token, "."),
         {:ok, ^jkt, nonce} <- proved(conn, token) do
      if nonce == @nonce, do: answer.(conn), else: nonce_challenge(conn)
    else
      _refused ->
        conn
        |> put_resp_header("www-authenticate", ~s(DPoP error="invalid_token"))
        |> send_resp(401, "")
    end
  end

  defp nonce_challenge(conn) do
    send(self(), {:fake_access, :nonce, :resource})

    conn
    |> put_resp_header("www-authenticate", ~s(DPoP error="use_dpop_nonce"))
    |> put_resp_header("dpop-nonce", @nonce)
    |> send_resp(401, "")
  end

  defp proved(conn, token) do
    with [proof] <- get_req_header(conn, "dpop"),
         {:ok, header, claims, input, sig} <- parts(proof),
         %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk} <- header,
         {:ok, point} <- point(jwk),
         true <- es256?(input, sig, point),
         true <- claims["htm"] == conn.method and claims["htu"] == url(conn),
         true <- claims["ath"] == ath(token),
         true <- is_binary(claims["jti"]) do
      {:ok, thumbprint(jwk), claims["nonce"]}
    else
      _refused -> :error
    end
  end

  defp tenant_snapshot(conn, "tnt_unknown" <> _rest), do: send_resp(conn, 404, "")

  defp tenant_snapshot(conn, tenant) do
    send(self(), {:fake_access, :snapshot, tenant})
    json(conn, snapshot(tenant))
  end

  defp evaluation(conn) do
    {:ok, body, conn} = read_body(conn)
    send(self(), {:fake_access, :evaluation, Jason.decode!(body)})
    json(conn, %{"decision" => true, "context" => %{"decision_ref" => "decision-1"}})
  end

  defp realm_discovery(slug) do
    issuer = @issuer <> "/realms/" <> slug
    %{"issuer" => issuer, "jwks_uri" => issuer <> "/jwks"}
  end

  defp realm_jwks(conn, slug) do
    realm = String.last(slug)
    send(self(), {:fake_access, :realm_keys, slug})
    {<<4, x::binary-32, y::binary-32>>, _private} = Map.fetch!(@realm_keys, realm)
    jwk = %{"kty" => "EC", "crv" => "P-256", "x" => b64(x), "y" => b64(y), "use" => "sig"}
    json(conn, %{"keys" => [Map.merge(jwk, %{"kid" => "realm-" <> realm, "alg" => "ES256"})]})
  end

  defp parts(jws) do
    with [encoded_header, encoded_claims, encoded_sig] <- String.split(jws, "."),
         {:ok, header} <- json_part(encoded_header),
         {:ok, claims} <- json_part(encoded_claims),
         {:ok, sig} <- Base.url_decode64(encoded_sig, padding: false) do
      {:ok, header, claims, encoded_header <> "." <> encoded_claims, sig}
    else
      _malformed -> :error
    end
  end

  defp json_part(encoded) do
    with {:ok, raw} <- Base.url_decode64(encoded, padding: false), do: Jason.decode(raw)
  end

  defp point(%{"kty" => "EC", "crv" => "P-256", "x" => x, "y" => y}) do
    with {:ok, x} <- Base.url_decode64(x, padding: false),
         {:ok, y} <- Base.url_decode64(y, padding: false),
         do: {:ok, <<4, x::binary, y::binary>>}
  end

  defp point(_jwk), do: :error

  defp es256?(input, <<r::256, s::256>>, point) do
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    :crypto.verify(:ecdsa, :sha256, input, der, [point, :secp256r1])
  end

  defp es256?(_input, _sig, _point), do: false

  defp thumbprint(%{"x" => x, "y" => y}),
    do: b64(:crypto.hash(:sha256, ~s({"crv":"P-256","kty":"EC","x":"#{x}","y":"#{y}"})))

  defp ath(nil), do: nil
  defp ath(token), do: b64(:crypto.hash(:sha256, token))

  defp url(conn), do: "#{conn.scheme}://#{conn.host}#{conn.request_path}"

  defp oauth_error(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => error}))
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

  # E-93
  @doc "A DPoP-bound client credentials token of an Access client for the server API (`aud` Relay's Access `client_id`, `cnf.jkt` the proof key of `RelayTest.Dpop`); `claims` override the defaults, and a nil value removes a claim."
  @spec server_token(String.t(), String.t(), String.t() | nil, map()) :: String.t()
  def server_token(access_tenant_id, client_id, scope, claims \\ %{}) do
    %{
      "sub" => client_id,
      "client_id" => client_id,
      "access_tenant" => access_tenant_id,
      "scope" => scope
    }
    |> Map.merge(claims)
    |> token()
  end

  # E-93
  @doc "An end user's DPoP-bound Access token for the subscriber token exchange, with the `sid` of the user's Access session; `claims` override the defaults."
  @spec user_token(String.t(), String.t(), String.t(), map()) :: String.t()
  def user_token(access_tenant_id, client_id, sub, claims \\ %{}) do
    %{
      "sub" => sub,
      "sid" => random(),
      "client_id" => client_id,
      "access_tenant" => access_tenant_id
    }
    |> Map.merge(claims)
    |> token()
  end

  # E-93
  @doc "The headers of a subscriber token exchange of `token`: the form content type and a fresh DPoP proof of the token's key."
  @spec exchange_headers(String.t()) :: [{String.t(), String.t()}]
  def exchange_headers(token) do
    url = RelayTest.Dpop.base() <> "/v1/subscriber/token"

    [
      {"content-type", "application/x-www-form-urlencoded"},
      {"dpop", RelayTest.Dpop.proof(:post, url, token)}
    ]
  end

  # E-93
  @doc "The options of `Relay.Access.verify_server_token/2` for `token` presented with a fresh proof on `method` and `path`."
  @spec presented(String.t(), String.t(), String.t()) :: keyword()
  def presented(token, method \\ "GET", path \\ "/v1/virtual_clock") do
    url = RelayTest.Dpop.base() <> path
    [proof: RelayTest.Dpop.proof(method, url, token), method: method, url: url]
  end

  @doc "Signs claims with the fake ES256 key, or the ES256 key pair `key`; `iss`, `aud` (Relay's Access `client_id`), `iat`, `nbf`, `exp` (a token valid for five minutes), `jti` and `cnf.jkt` (the proof key of `RelayTest.Dpop`) have defaults, and a nil value removes a claim."
  @spec token(map(), map(), {binary(), binary()}) :: String.t()
  def token(claims, header \\ %{}, key \\ @es256) do
    now = System.system_time(:second)

    defaults = %{
      "iss" => @issuer,
      "aud" => Relay.Access.client_id(),
      "iat" => now,
      "nbf" => now,
      "exp" => now + 300,
      "jti" => random(),
      "cnf" => %{"jkt" => RelayTest.Dpop.jkt()}
    }

    claims = defaults |> Map.merge(claims) |> Map.reject(fn {_name, value} -> is_nil(value) end)
    header = Map.merge(%{"alg" => "ES256", "typ" => "at+jwt", "kid" => "fake-es256"}, header)
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    {_public, private} = key
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
