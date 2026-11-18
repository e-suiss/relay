defmodule EsuissRelay.Credentials.AccessClient do
  @moduledoc """
  Obtains DPoP-bound access tokens from Access with the OAuth 2.0 client credentials grant.

  Options of `new/1`:

    * `:token_endpoint` - the Access token endpoint (required, https)
    * `:client_id`, `:client_secret` - the Access API client (required)
    * `:resource` - Relay's Access client id, `access_client_id` in Relay's discovery document
      (required)
    * `:scope` - space separated scopes to narrow the token to (optional)
    * `:key` - the `EsuissRelay.DpopKey` (default: a newly generated key)

  The client authenticates with HTTP Basic, sends a DPoP proof, answers one `use_dpop_nonce`
  challenge and caches the token until 30 seconds before it expires. The cache lives in an
  `Agent` linked to the caller of `new/1`.
  """

  alias EsuissRelay.Client
  alias EsuissRelay.DpopKey
  alias EsuissRelay.Error

  @enforce_keys [:token_endpoint, :client_id, :client_secret, :resource, :key, :cache]
  defstruct [:token_endpoint, :client_id, :client_secret, :resource, :scope, :key, :cache]

  @type t :: %__MODULE__{
          token_endpoint: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          resource: String.t(),
          scope: String.t() | nil,
          key: DpopKey.t(),
          cache: pid()
        }

  @skew 30

  @doc "Credentials of an Access API client."
  @spec new(keyword()) :: t()
  def new(opts) do
    {:ok, cache} = Agent.start_link(fn -> nil end)

    %__MODULE__{
      token_endpoint: Keyword.fetch!(opts, :token_endpoint),
      client_id: Keyword.fetch!(opts, :client_id),
      client_secret: Keyword.fetch!(opts, :client_secret),
      resource: Keyword.fetch!(opts, :resource),
      scope: Keyword.get(opts, :scope),
      key: Keyword.get_lazy(opts, :key, &DpopKey.generate/0),
      cache: cache
    }
  end

  @doc "The cached token, or a new one when none is cached or it is about to expire."
  @spec fetch(t(), Client.t()) :: {:ok, String.t(), DpopKey.t()} | {:error, Error.t()}
  def fetch(%__MODULE__{} = credentials, %Client{} = client) do
    now = client.clock.()

    case Agent.get(credentials.cache, & &1) do
      {token, expires_at} when expires_at > now ->
        {:ok, token, credentials.key}

      _none ->
        refresh(credentials, client, now)
    end
  end

  defp refresh(credentials, client, now) do
    with {:ok, token, expires_in} <- request(credentials, client, nil) do
      Agent.update(credentials.cache, fn _ -> {token, now + expires_in - @skew} end)
      {:ok, token, credentials.key}
    end
  end

  @doc "Forgets the cached token."
  @spec reset(t()) :: :ok
  def reset(%__MODULE__{cache: cache}), do: Agent.update(cache, fn _ -> nil end)

  defp request(credentials, client, nonce) do
    form =
      [
        {"grant_type", "client_credentials"},
        {"resource", credentials.resource}
      ] ++ if(credentials.scope, do: [{"scope", credentials.scope}], else: [])

    proof =
      DpopKey.proof(
        credentials.key,
        "POST",
        credentials.token_endpoint,
        nil,
        nonce,
        client.clock.(),
        client.random_bytes.(16)
      )

    basic =
      Base.encode64(
        URI.encode_www_form(credentials.client_id) <>
          ":" <> URI.encode_www_form(credentials.client_secret)
      )

    request = %{
      method: :post,
      url: credentials.token_endpoint,
      headers: [
        {"accept", "application/json"},
        {"content-type", "application/x-www-form-urlencoded"},
        {"authorization", "Basic " <> basic},
        {"dpop", proof},
        {"user-agent", Client.user_agent()}
      ],
      body: URI.encode_query(form, :www_form),
      timeout: client.timeout
    }

    case Client.transport(client, request) do
      {:ok, response} -> answer(credentials, client, nonce, response)
      {:error, reason} -> {:error, Error.connection(reason)}
    end
  end

  defp answer(credentials, client, nonce, %{status: status} = response) do
    body = decode(response.body)

    case {status, body} do
      {200, %{"access_token" => token, "token_type" => type} = issued}
      when is_binary(token) and token != "" and is_binary(type) ->
        issued(token, type, issued["expires_in"])

      {400, %{"error" => "use_dpop_nonce"}} when is_nil(nonce) ->
        retry_with_nonce(credentials, client, Client.header(response.headers, "dpop-nonce"))

      {status, body} when status == 429 or status >= 500 ->
        {:error, Error.from_response(status, nil, body, nil)}

      {status, body} ->
        {:error, refused(status, oauth_error(body), body["error_description"])}
    end
  end

  defp issued(token, type, expires_in) do
    if String.downcase(type) == "dpop",
      do: {:ok, token, if(is_integer(expires_in), do: expires_in, else: 60)},
      else: {:error, refused(200, "access_token_type", "Access did not issue a DPoP token")}
  end

  defp retry_with_nonce(credentials, client, nonce) when is_binary(nonce) and nonce != "",
    do: request(credentials, client, nonce)

  defp retry_with_nonce(_credentials, _client, _nonce),
    do: {:error, refused(400, "access_use_dpop_nonce", "Access asked for a nonce without one")}

  defp oauth_error(%{"error" => error}) when is_binary(error), do: "access_" <> error
  defp oauth_error(_body), do: "access_token_refused"

  defp refused(status, code, detail) do
    %EsuissRelay.AuthenticationError{
      status: status,
      code: code,
      detail: if(is_binary(detail), do: detail),
      retryable: false
    }
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defimpl EsuissRelay.Credentials do
    def token(credentials, client), do: @for.fetch(credentials, client)
  end

  defimpl Inspect do
    def inspect(credentials, _opts),
      do: "#EsuissRelay.Credentials.AccessClient<" <> credentials.client_id <> ">"
  end
end
