defmodule Relay.Messaging.TeamsAuth do
  @moduledoc """
  The authentication of a Bot Framework request to a Teams bot (CH-62, T-40): the `Authorization: Bearer` JWT is signed with RS256 by a key of the Bot Framework's published key set, its issuer is `https://api.botframework.com`, its audience is the bot's Microsoft App ID, and its `serviceurl` claim names the activity's `serviceUrl`. The key set is read from the Bot Framework for each request, with no cache, and only the key named by the token's `kid` is used.
  """

  @issuer "https://api.botframework.com"
  @keys "https://login.botframework.com/v1/.well-known/keys"

  # CH-62
  # T-40
  @doc "Verifies a request's bearer token for the bot `app_id` at `now` and the activity's service URL."
  @spec verify(String.t() | nil, String.t(), String.t() | nil, DateTime.t(), keyword()) ::
          :ok | {:error, :bad_signature | :stale_timestamp | :keys_unavailable}
  def verify("Bearer " <> token, app_id, service_url, now, opts) do
    with {:ok, kid} <- kid(token),
         {:ok, pem} <- key(kid, opts),
         {:ok, claims} <-
           Relay.Channels.verify_jwt(Relay.Redacted.wrap(pem), token, algs: ["RS256"], now: now) do
      claims(claims, app_id, service_url)
    end
  end

  def verify(_authorization, _app_id, _service_url, _now, _opts), do: {:error, :bad_signature}

  defp kid(token) do
    with [header | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(header, padding: false),
         {:ok, %{"kid" => kid, "alg" => "RS256"}} when is_binary(kid) <- Jason.decode(json) do
      {:ok, kid}
    else
      _invalid -> {:error, :bad_signature}
    end
  end

  defp claims(%{"iss" => @issuer, "aud" => app_id} = claims, app_id, service_url) do
    case Map.get(claims, "serviceurl") do
      nil -> :ok
      ^service_url -> :ok
      _other -> {:error, :bad_signature}
    end
  end

  defp claims(_claims, _app_id, _service_url), do: {:error, :bad_signature}

  defp key(kid, opts) do
    request =
      Keyword.merge([method: :get, url: @keys, receive_timeout: 5000, decode_body: false], opts)

    with {:ok, %Req.Response{status: 200, body: body}} <- Relay.Channels.http_request(request),
         {:ok, %{"keys" => keys}} when is_list(keys) <- Jason.decode(body),
         %{"n" => n, "e" => e} <- Enum.find(keys, &(&1["kid"] == kid and &1["kty"] == "RSA")) do
      pem(n, e)
    else
      nil -> {:error, :bad_signature}
      _unavailable -> {:error, :keys_unavailable}
    end
  end

  @doc "The PEM public key of an RSA JWK's modulus and exponent (base64url)."
  @spec pem(String.t(), String.t()) :: {:ok, String.t()} | {:error, :bad_signature}
  def pem(n, e) when is_binary(n) and is_binary(e) do
    with {:ok, modulus} <- Base.url_decode64(n, padding: false),
         {:ok, exponent} <- Base.url_decode64(e, padding: false) do
      key = {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}
      entry = :public_key.pem_entry_encode(:SubjectPublicKeyInfo, key)
      {:ok, :public_key.pem_encode([entry])}
    else
      _invalid -> {:error, :bad_signature}
    end
  end

  def pem(_n, _e), do: {:error, :bad_signature}
end
