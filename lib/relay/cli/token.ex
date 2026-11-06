defmodule Relay.CLI.Token do
  @moduledoc """
  Access token client of the command line tool (E-93). Relay's own Access `client_id` comes from Relay's discovery document (`<api url>/.well-known/relay-configuration`, `access_client_id`); the token endpoint is discovered from the Access issuer (`<issuer>/.well-known/openid-configuration`, whose `issuer` must be the configured one). The token is obtained with the OAuth 2.0 client credentials grant for `resource` Relay's `client_id` (RFC 8707), with `client_secret_basic` unless the issuer supports only `client_secret_post`, and is bound to an Ed25519 DPoP key made for the run (RFC 9449): the token request carries a proof of that key, and a `use_dpop_nonce` answer is sent once more with the nonce Access names. Access must answer with a `DPoP` token.

  Every Relay API call carries the token as `Authorization: DPoP` with a fresh proof (`proof/4`). The key, the secret and the token are kept in memory for the rest of the run and are never printed.
  """

  alias Relay.CLI.Config
  alias Relay.CLI.Context
  alias Relay.CLI.Failure
  alias Relay.CLI.HTTP

  @key {__MODULE__, :dpop_key}
  @resource {__MODULE__, :resource}

  # E-78
  # E-93
  # API-41
  @doc "Returns an access token for the API client of `environment`, from memory or from Access."
  @spec fetch(Context.t(), Config.environment()) ::
          {:ok, Relay.Redacted.t()} | {:error, Failure.t()}
  def fetch(%Context{} = ctx, environment) do
    case Process.get({__MODULE__, environment}) do
      nil -> obtain(ctx, environment)
      token -> {:ok, token}
    end
  end

  @doc "Forgets the token of `environment`; the next `fetch/2` asks Access again."
  @spec forget(Config.environment()) :: :ok
  def forget(environment) do
    Process.delete({__MODULE__, environment})
    :ok
  end

  @doc "Forgets every token, the DPoP key and Relay's discovered `client_id`."
  @spec forget_all() :: :ok
  def forget_all do
    forget(:test)
    forget(:live)
    Process.delete(@key)
    Process.delete(@resource)
    :ok
  end

  # E-93
  @doc "A DPoP proof of the run's key for a request: `method`, `url` without query and fragment, and the token it carries (nil at the token endpoint), with an optional server `nonce`."
  @spec proof(Context.t(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          String.t()
  def proof(%Context{} = ctx, method, url, token, nonce \\ nil) do
    {public, private} = key(ctx)
    jwk = %{"kty" => "OKP", "crv" => "Ed25519", "x" => b64(public)}
    header = %{"typ" => "dpop+jwt", "alg" => "Ed25519", "jwk" => jwk}

    claims =
      %{
        "htm" => method,
        "htu" => url |> String.split(["?", "#"]) |> hd(),
        "iat" => DateTime.to_unix(ctx.now.()),
        "jti" => b64(ctx.random_bytes.(16))
      }
      |> put_claim("ath", token && b64(:crypto.hash(:sha256, token)))
      |> put_claim("nonce", nonce)

    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [private, :ed25519]))
  end

  defp put_claim(claims, _name, nil), do: claims
  defp put_claim(claims, name, value), do: Map.put(claims, name, value)

  defp key(ctx) do
    case Process.get(@key) do
      nil ->
        key = :crypto.generate_key(:eddsa, :ed25519, ctx.random_bytes.(32))
        Process.put(@key, key)
        key

      key ->
        key
    end
  end

  defp obtain(ctx, environment) do
    config = ctx.config
    credential = Map.fetch!(config.credentials, environment)

    with {:ok, resource} <- resource(ctx, config.api_url),
         {:ok, endpoint, methods} <- discover(ctx, config.issuer),
         grant = %{
           endpoint: endpoint,
           methods: methods,
           credential: credential,
           scope: config.scope,
           resource: resource
         },
         {:ok, token} <- request(ctx, grant, nil) do
      redacted = Relay.Redacted.wrap(token)
      Process.put({__MODULE__, environment}, redacted)
      {:ok, redacted}
    end
  end

  # E-81
  # E-90
  defp resource(ctx, api_url) do
    case Process.get(@resource) do
      nil -> relay_discovery(ctx, api_url)
      resource -> {:ok, resource}
    end
  end

  defp relay_discovery(ctx, api_url) do
    url = api_url <> "/.well-known/relay-configuration"

    case HTTP.request(ctx, method: :get, url: url, headers: [{"accept", "application/json"}]) do
      {:ok, %{status: 200, body: %{"access_client_id" => resource}}}
      when is_binary(resource) and resource != "" ->
        Process.put(@resource, resource)
        {:ok, resource}

      {:ok, %{status: 200}} ->
        discovery_failed("the Relay discovery document names no access_client_id")

      {:ok, %{status: status} = response} when status == 429 or status >= 500 ->
        {:error, Failure.from_response(response)}

      {:ok, %{status: status}} ->
        discovery_failed("Relay answered HTTP #{status} to the discovery request")

      {:error, reason} ->
        relay_unreachable(reason)
    end
  end

  defp relay_unreachable(reason) do
    message = "Relay is unreachable: " <> reason
    {:error, Failure.new(:unavailable, "connection_failed", message)}
  end

  defp discover(ctx, issuer) do
    url = issuer <> "/.well-known/openid-configuration"

    case HTTP.request(ctx, method: :get, url: url, headers: [{"accept", "application/json"}]) do
      {:ok, %{status: 200, body: %{"issuer" => found, "token_endpoint" => endpoint} = document}}
      when is_binary(found) and is_binary(endpoint) ->
        discovered(issuer, found, endpoint, document)

      {:ok, %{status: 200}} ->
        discovery_failed("the discovery document has no issuer or token_endpoint")

      {:ok, %{status: status} = response} when status == 429 or status >= 500 ->
        {:error, Failure.from_response(response)}

      {:ok, %{status: status}} ->
        discovery_failed("Access answered HTTP #{status} to the discovery request")

      {:error, reason} ->
        unreachable(reason)
    end
  end

  defp discovered(issuer, found, endpoint, document) do
    cond do
      String.trim_trailing(found, "/") != issuer ->
        discovery_failed("the discovery document names another issuer: " <> found)

      not Config.secure_url?(endpoint) ->
        discovery_failed("the token endpoint is not an https URL")

      true ->
        {:ok, endpoint, document["token_endpoint_auth_methods_supported"]}
    end
  end

  # E-93
  defp request(ctx, grant, nonce) do
    form =
      [grant_type: "client_credentials", resource: grant.resource] ++
        if(grant.scope, do: [scope: grant.scope], else: [])

    {form, headers} = client_authentication(form, grant.credential, grant.methods)
    dpop = proof(ctx, "POST", grant.endpoint, nil, nonce)
    headers = [{"accept", "application/json"}, {"dpop", dpop} | headers]

    case HTTP.request(ctx, method: :post, url: grant.endpoint, form: form, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        issued(body)

      {:ok, %{status: 400, body: %{"error" => "use_dpop_nonce"}} = response} when is_nil(nonce) ->
        again_with_nonce(ctx, grant, HTTP.header(response, "dpop-nonce"))

      {:ok, %{status: status} = response} when status == 429 or status >= 500 ->
        {:error, Failure.from_response(response)}

      {:ok, %{body: body}} ->
        {:error, Failure.new(:auth, "access_" <> oauth_error(body), oauth_description(body))}

      {:error, reason} ->
        unreachable(reason)
    end
  end

  defp again_with_nonce(ctx, grant, nonce) when is_binary(nonce) and nonce != "",
    do: request(ctx, grant, nonce)

  defp again_with_nonce(_ctx, _grant, _nonce),
    do: token_refused("Access asked for a DPoP nonce without naming one")

  defp issued(%{"access_token" => token, "token_type" => type})
       when is_binary(token) and token != "" and is_binary(type) do
    if String.downcase(type) == "dpop",
      do: {:ok, token},
      else: token_refused("Access issued a #{type} token, not a DPoP token")
  end

  defp issued(_body), do: token_refused("Access answered without a DPoP access token")

  defp client_authentication(form, credential, methods) do
    id = credential.client_id
    secret = Relay.Redacted.expose(credential.client_secret)

    if post_only?(methods) do
      {form ++ [client_id: id, client_secret: secret], []}
    else
      basic = Base.encode64(URI.encode_www_form(id) <> ":" <> URI.encode_www_form(secret))
      {form, [{"authorization", "Basic " <> basic}]}
    end
  end

  defp post_only?(methods) when is_list(methods),
    do: "client_secret_post" in methods and "client_secret_basic" not in methods

  defp post_only?(_methods), do: false

  defp oauth_error(%{"error" => error}) when is_binary(error) do
    if Regex.match?(~r/\A[a-z_]{1,64}\z/, error), do: error, else: "token_refused"
  end

  defp oauth_error(_body), do: "token_refused"

  defp oauth_description(%{"error_description" => text}) when is_binary(text),
    do: "Access refused the client credentials: " <> text

  defp oauth_description(_body), do: "Access refused the client credentials"

  defp discovery_failed(message),
    do: {:error, Failure.new(:auth, "access_discovery_failed", message)}

  defp token_refused(message) do
    {:error, Failure.new(:auth, "access_token_refused", message)}
  end

  defp unreachable(reason) do
    message = "Access is unreachable: " <> reason
    {:error, Failure.new(:unavailable, "access_unreachable", message)}
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
