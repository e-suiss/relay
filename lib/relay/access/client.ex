defmodule Relay.Access.Client do
  @moduledoc """
  Relay's own calls to Access (E-98, E-100): AuthZEN decisions and the token requests they rest on, and the Access product routes such as the tenant snapshot. Every call is signed in the key store (TN-63) with Relay's Access client key, the P-256 key named by `config :relay, Relay.Access, client_key: label` (`access-client` by default). Its public JWK is registered with Relay's client in Access (`[[products]] client_key`); `print_client_key/0` prints it (`bin/relay eval 'Relay.Access.Client.print_client_key()'`, or `mix relay.access.client_key` in development).

  * `product_get/2` reads a product route with `Authorization: Bearer` and a fresh RFC 7523 client assertion (E-100): ES256, `iss` and `sub` Relay's Access `client_id`, `aud` the linked (platform realm) issuer, a single-use `jti` and an `exp` one minute ahead. No access token is involved.

  * `get/3` and `post/3` call an Access resource with Relay's Access access token as `Authorization: DPoP` and a proof naming the method, the URL and the token (`ath`).
  * The token comes from the client credentials grant at the linked issuer's token endpoint (`token/3`): the request is authenticated with a `private_key_jwt` client assertion (RFC 7523; `iss` and `sub` Relay's Access `client_id`, `aud` the linked issuer, signed with the same key) and carries a proof, so the token is bound to that key; Access must answer with a `DPoP` token. The token is kept in `Relay.Access.Cache` until 30 seconds before it expires and forgotten when Access refuses it.
  * A `use_dpop_nonce` answer (400 at the token endpoint, 401 with a `DPoP` challenge at a resource) is sent once more with the nonce Access names in `DPoP-Nonce`; the last nonce of each Access origin goes into the next proof to that origin.

  A 200 answer is decoded as a JSON object; a 404 is `{:error, :not_found}`; any other answer, a transport failure and a key store failure are `access_unreachable`.
  """

  alias Relay.Access.Cache
  alias Relay.Access.Dpop
  alias Relay.Access.Http
  alias Relay.Access.Jose
  alias Relay.Access.Link

  @token {__MODULE__, :access_token}
  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @margin_s 30
  @default_ttl_s 60
  @assertion_s 60
  @nonce_ms 300_000
  @jwk_ms 600_000

  @type result :: {:ok, map()} | {:error, :not_found} | {:error, Relay.Error.t()}

  # E-98
  # E-95
  # E-96
  @doc "Reads an Access resource: `GET url` with `query` (a keyword list or map of query members, or `[]`), as Relay with its DPoP-bound Access access token. Options: `:http`, extra Req options."
  @spec get(String.t(), keyword() | map(), keyword()) :: result()
  def get(url, query \\ [], opts \\ []) when is_binary(url) do
    url = if Enum.empty?(query), do: url, else: url <> "?" <> URI.encode_query(query)
    resource(%{verb: :get, method: "GET", url: url, body: nil}, opts)
  end

  # E-100
  # E-95
  # E-96
  @doc "Reads an Access product route (such as the tenant snapshot) as Relay, authenticated by a fresh RFC 7523 client assertion sent as `Authorization: Bearer`. Options: `:http`, extra Req options."
  @spec product_get(String.t(), keyword()) :: result()
  def product_get(url, opts \\ []) when is_binary(url) do
    with {:ok, client_id} <- client_id(),
         {:ok, issuer} <- issuer(),
         {:ok, assertion} <- assertion(client_id, issuer),
         headers = [{"accept", "application/json"}, {"authorization", "Bearer " <> assertion}],
         {:ok, response} <- call(url, [method: :get, headers: headers], opts),
         do: product_answer(response)
  end

  # E-100
  # E-101
  @doc "Sends `method` (`:get` or `:post`) to an Access platform route (the pairing routes and the platform streams) as Relay, authenticated by a fresh RFC 7523 client assertion sent as `Authorization: Bearer`, with `body` as JSON when it is a map; the response comes back as it is, its body raw bytes. Options: `:http`, extra Req options."
  @spec product_request(:get | :post, String.t(), map() | nil, keyword()) ::
          {:ok, Req.Response.t()} | {:error, Relay.Error.t()}
  def product_request(method, url, body, opts \\ [])
      when method in [:get, :post] and is_binary(url) do
    with {:ok, client_id} <- client_id(),
         {:ok, issuer} <- issuer(),
         {:ok, assertion} <- assertion(client_id, issuer) do
      headers = [{"accept", "application/json"}, {"authorization", "Bearer " <> assertion}]
      json = if is_map(body), do: [body: Jason.encode!(body)], else: []
      type = if is_map(body), do: [{"content-type", "application/json"}], else: []
      call(url, [method: method, headers: headers ++ type] ++ json, opts)
    end
  end

  # E-100
  @doc "Prints the public JWK of Relay's Access client key, to register it with Relay's client in Access; it starts the key store port when the node does not run it."
  @spec print_client_key() :: :ok
  def print_client_key do
    _started =
      Supervisor.start_link(Relay.Keys.children(),
        strategy: :one_for_one,
        max_restarts: 0,
        max_seconds: 1
      )

    case public_jwk() do
      {:ok, jwk} -> IO.puts(Jason.encode!(Map.merge(jwk, %{"alg" => "ES256", "use" => "sig"})))
      {:error, error} -> raise error.message
    end
  end

  # E-98
  # E-27
  @doc "Posts a JSON object to an Access resource as Relay with its DPoP-bound Access access token. Options: `:http`, extra Req options."
  @spec post(String.t(), map(), keyword()) :: result()
  def post(url, body, opts \\ []) when is_binary(url) and is_map(body),
    do: resource(%{verb: :post, method: "POST", url: url, body: Jason.encode!(body)}, opts)

  # E-98
  @doc "Relay's own Access access token, from the cache or from a client credentials grant."
  @spec access_token(keyword()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def access_token(opts \\ []) do
    case Cache.fetch(@token) do
      {:ok, token} -> {:ok, Relay.Redacted.expose(token)}
      :miss -> issue(opts)
    end
  end

  @doc "Forgets Relay's cached Access access token."
  @spec forget_token() :: :ok
  def forget_token, do: Cache.delete(@token)

  # E-98
  # E-26
  @doc "Sends a token request with `form` (its `grant_type` and members) to `endpoint`, authenticated by Relay's client assertion and carrying a DPoP proof, and returns the decoded answer of a 200; an OAuth refusal (4xx) is `{:error, {:refused, body}}` with the decoded error body."
  @spec token(String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, {:refused, map()}} | {:error, Relay.Error.t()}
  def token(endpoint, form, opts \\ []) when is_binary(endpoint) and is_list(form) do
    with {:ok, client_id} <- client_id(),
         {:ok, issuer} <- issuer(),
         attempt = fn nonce -> token_call(endpoint, form, {client_id, issuer}, nonce, opts) end,
         {:ok, response} <- exchange(attempt, nonce(endpoint), :token),
         do: token_answer(response)
  end

  # E-98
  @doc "A DPoP proof of Relay's key for a call to Access: `method`, `url` without query and fragment, the access token it carries (nil at a token endpoint) and the server's nonce (nil when none is known)."
  @spec proof(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, Relay.Error.t()}
  def proof(method, url, token, nonce) do
    with {:ok, jwk} <- public_jwk() do
      claims =
        %{
          "htm" => method,
          "htu" => url |> String.split(["?", "#"]) |> hd(),
          "iat" => now(),
          "jti" => Jose.encode(Relay.Random.bytes(16))
        }
        |> put_claim("ath", token && Dpop.token_hash(token))
        |> put_claim("nonce", nonce)

      sign(%{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => jwk}, claims)
    end
  end

  # E-98
  # E-100
  @doc "The public JWK of Relay's Access client key, read from the key store."
  @spec public_jwk() :: {:ok, map()} | {:error, Relay.Error.t()}
  def public_jwk do
    label = key_label()

    case Cache.fetch({:client_jwk, label}) do
      {:ok, jwk} -> {:ok, jwk}
      :miss -> read_jwk(label)
    end
  end

  defp read_jwk(label) do
    case Relay.Keys.public_key(:es256, label) do
      {:ok, <<4, x::binary-32, y::binary-32>>} ->
        jwk = %{"kty" => "EC", "crv" => "P-256", "x" => Jose.encode(x), "y" => Jose.encode(y)}
        :ok = Cache.put({:client_jwk, label}, jwk, @jwk_ms)
        {:ok, jwk}

      _failed ->
        unreachable("Relay's Access client key cannot be read")
    end
  end

  defp resource(request, opts) do
    with {:ok, token} <- access_token(opts),
         attempt = fn nonce -> resource_call(request, token, nonce, opts) end,
         {:ok, response} <- exchange(attempt, nonce(request.url), :resource),
         do: answer(response)
  end

  defp resource_call(request, token, nonce, opts) do
    with {:ok, proof} <- proof(request.method, request.url, token, nonce) do
      headers = [
        {"accept", "application/json"},
        {"authorization", "DPoP " <> token},
        {"dpop", proof}
      ]

      body = if request.body, do: [body: request.body], else: []
      type = if request.body, do: [{"content-type", "application/json"}], else: []
      call(request.url, [method: request.verb, headers: headers ++ type] ++ body, opts)
    end
  end

  defp token_call(endpoint, form, {client_id, issuer}, nonce, opts) do
    with {:ok, assertion} <- assertion(client_id, issuer),
         {:ok, proof} <- proof("POST", endpoint, nil, nonce) do
      authentication = [
        client_id: client_id,
        client_assertion_type: @assertion_type,
        client_assertion: assertion
      ]

      headers = [{"accept", "application/json"}, {"dpop", proof}]
      call(endpoint, [method: :post, form: form ++ authentication, headers: headers], opts)
    end
  end

  defp call(url, request, opts) do
    with {:ok, response} <- Http.request([url: url] ++ request ++ Keyword.get(opts, :http, [])) do
      :ok = remember_nonce(url, response)
      {:ok, response}
    end
  end

  defp exchange(attempt, nonce, kind) do
    with {:ok, response} <- attempt.(nonce) do
      case asked_nonce(response, kind) do
        {:ok, fresh} -> attempt.(fresh)
        :none -> {:ok, response}
      end
    end
  end

  defp asked_nonce(response, kind) do
    with true <- nonce_error?(response, kind),
         nonce when is_binary(nonce) and nonce != "" <- header(response, "dpop-nonce") do
      {:ok, nonce}
    else
      _other -> :none
    end
  end

  defp nonce_error?(%Req.Response{status: 400, body: body}, :token) when is_binary(body),
    do: match?({:ok, %{"error" => "use_dpop_nonce"}}, Jason.decode(body))

  defp nonce_error?(%Req.Response{status: 401} = response, :resource),
    do: String.contains?(header(response, "www-authenticate") || "", "use_dpop_nonce")

  defp nonce_error?(_response, _kind), do: false

  defp answer(%Req.Response{status: 200, body: body}) do
    with {:ok, document, _raw} <- Http.json(body), do: {:ok, document}
  end

  defp answer(%Req.Response{status: 404}), do: {:error, :not_found}

  defp answer(%Req.Response{status: 401}) do
    :ok = forget_token()
    unreachable("Access refused Relay's access token")
  end

  defp answer(%Req.Response{status: status}), do: unreachable("Access answered #{status}")

  defp product_answer(%Req.Response{status: 401}),
    do: unreachable("Access refused Relay's client assertion")

  defp product_answer(response), do: answer(response)

  defp token_answer(%Req.Response{status: 200, body: body}) do
    with {:ok, document, _raw} <- Http.json(body), do: {:ok, document}
  end

  defp token_answer(%Req.Response{status: status, body: body}) when status in 400..499 do
    case Http.json(body) do
      {:ok, document, _raw} -> {:error, {:refused, document}}
      {:error, _error} -> {:error, {:refused, %{}}}
    end
  end

  defp token_answer(%Req.Response{status: status}),
    do: unreachable("Access answered #{status} to the token request")

  defp issue(opts) do
    with {:ok, endpoint} <- token_endpoint(),
         {:ok, body} <- granted(token(endpoint, [grant_type: "client_credentials"], opts)),
         {:ok, token, ttl_s} <- issued(body) do
      :ok = Cache.put(@token, Relay.Redacted.wrap(token), max(ttl_s - @margin_s, 0) * 1000)
      {:ok, token}
    end
  end

  defp granted({:ok, body}), do: {:ok, body}
  defp granted({:error, {:refused, _body}}), do: unreachable("Access refused Relay's grant")
  defp granted({:error, error}), do: {:error, error}

  defp issued(%{"access_token" => token, "token_type" => type} = body)
       when is_binary(token) and token != "" and is_binary(type) do
    if String.downcase(type) == "dpop",
      do: {:ok, token, ttl(body["expires_in"])},
      else: unreachable("Access issued a #{type} token, not a DPoP token")
  end

  defp issued(_body), do: unreachable("Access answered without a DPoP access token")

  defp ttl(seconds) when is_integer(seconds) and seconds > 0, do: seconds
  defp ttl(_seconds), do: @default_ttl_s

  defp token_endpoint do
    case Link.current() do
      %{state: state, token_endpoint: endpoint}
      when state in [:ok, :stale] and is_binary(endpoint) ->
        {:ok, endpoint}

      _no_endpoint ->
        {:error, Relay.Error.new(:service_unavailable, "the Access link is not established")}
    end
  end

  # E-90
  defp client_id do
    case Relay.Access.client_id() do
      client_id when is_binary(client_id) and client_id != "" ->
        {:ok, client_id}

      _unset ->
        {:error, Relay.Error.new(:service_unavailable, "Relay's Access client_id is not set")}
    end
  end

  defp issuer do
    case Relay.Access.issuer() do
      issuer when is_binary(issuer) and issuer != "" ->
        {:ok, issuer}

      _unset ->
        {:error, Relay.Error.new(:access_not_configured, "no Access issuer is configured")}
    end
  end

  defp assertion(client_id, issuer) do
    now = now()

    claims = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => issuer,
      "iat" => now,
      "exp" => now + @assertion_s,
      "jti" => Jose.encode(Relay.Random.bytes(16))
    }

    sign(%{"alg" => "ES256", "typ" => "JWT"}, claims)
  end

  defp sign(header, claims) do
    input = Jose.encode(Jason.encode!(header)) <> "." <> Jose.encode(Jason.encode!(claims))

    case Relay.Keys.sign(:es256, key_label(), input) do
      {:ok, <<_::512>> = signature} -> {:ok, input <> "." <> Jose.encode(signature)}
      _failed -> unreachable("Relay's Access client key cannot sign")
    end
  end

  defp nonce(url) do
    case Cache.fetch({:dpop_nonce, origin(url)}) do
      {:ok, nonce} -> nonce
      :miss -> nil
    end
  end

  defp remember_nonce(url, response) do
    case header(response, "dpop-nonce") do
      nonce when is_binary(nonce) and nonce != "" ->
        Cache.put({:dpop_nonce, origin(url)}, nonce, @nonce_ms)

      _none ->
        :ok
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.port}
  end

  defp header(response, name), do: response |> Req.Response.get_header(name) |> List.first()

  defp put_claim(claims, _name, nil), do: claims
  defp put_claim(claims, name, value), do: Map.put(claims, name, value)

  defp key_label, do: Keyword.get(Relay.Access.config(), :client_key, "access-client")

  defp unreachable(message),
    do: {:error, Relay.Error.new(:access_unreachable, "Access link: " <> message)}

  defp now, do: DateTime.to_unix(Relay.Clock.utc_now())
end
