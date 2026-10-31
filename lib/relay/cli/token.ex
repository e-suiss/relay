defmodule Relay.CLI.Token do
  @moduledoc """
  Access token client of the command line tool. The token endpoint is discovered from the Access issuer (`<issuer>/.well-known/openid-configuration`, whose `issuer` must be the configured one); the token is obtained with the OAuth 2.0 client credentials grant, with `client_secret_basic` unless the issuer supports only `client_secret_post`, and is kept in memory for the rest of the run.

  When the token is a JWT whose payload names an environment (`environment` or `suiss_environment`), it must be the configured one; the payload is read for this check only and is not verified here. The secret and the token are never printed.
  """

  alias Relay.CLI.Config
  alias Relay.CLI.Context
  alias Relay.CLI.Failure
  alias Relay.CLI.HTTP

  @claims ["environment", "suiss_environment"]

  # E-78
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

  @doc "Forgets every token."
  @spec forget_all() :: :ok
  def forget_all do
    forget(:test)
    forget(:live)
  end

  # API-42
  @doc "Decodes the payload of a JWT without verifying it; nil for any other token."
  @spec claims(String.t()) :: map() | nil
  def claims(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      claims
    else
      _other -> nil
    end
  end

  defp obtain(ctx, environment) do
    config = ctx.config
    credential = Map.fetch!(config.credentials, environment)

    with {:ok, endpoint, methods} <- discover(ctx, config.issuer),
         {:ok, token} <- request(ctx, endpoint, methods, credential, config.scope),
         :ok <- same_environment(token, environment) do
      redacted = Relay.Redacted.wrap(token)
      Process.put({__MODULE__, environment}, redacted)
      {:ok, redacted}
    end
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

  defp request(ctx, endpoint, methods, credential, scope) do
    form = [grant_type: "client_credentials"] ++ if(scope, do: [scope: scope], else: [])
    {form, headers} = client_authentication(form, credential, methods)
    headers = [{"accept", "application/json"} | headers]

    case HTTP.request(ctx, method: :post, url: endpoint, form: form, headers: headers) do
      {:ok, %{status: 200, body: %{"access_token" => token, "token_type" => type}}}
      when is_binary(token) and is_binary(type) ->
        bearer(token, type)

      {:ok, %{status: 200}} ->
        token_refused("Access answered without a Bearer access token")

      {:ok, %{status: status} = response} when status == 429 or status >= 500 ->
        {:error, Failure.from_response(response)}

      {:ok, %{body: body}} ->
        {:error, Failure.new(:auth, "access_" <> oauth_error(body), oauth_description(body))}

      {:error, reason} ->
        unreachable(reason)
    end
  end

  defp bearer("", _type), do: token_refused("Access answered without a Bearer access token")

  defp bearer(token, type) do
    if String.downcase(type) == "bearer",
      do: {:ok, token},
      else: token_refused("Access issued a #{type} token, not a Bearer token")
  end

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

  defp same_environment(token, environment) do
    expected = Atom.to_string(environment)

    case named_environment(claims(token)) do
      nil ->
        :ok

      ^expected ->
        :ok

      other ->
        {:error,
         Failure.new(
           :auth,
           "credential_environment_mismatch",
           "the Access client is a #{other} client, but the command runs for #{expected}"
         )}
    end
  end

  defp named_environment(%{} = claims) do
    Enum.find_value(@claims, fn claim ->
      if is_binary(claims[claim]), do: claims[claim]
    end)
  end

  defp named_environment(nil), do: nil

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
end
