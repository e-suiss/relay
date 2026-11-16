defmodule Relay.Webhooks.Destination.Https do
  @moduledoc """
  The HTTPS webhook destination (WH-17): one `POST` of the structured body through `Relay.Webhooks.Egress`, so every rule of the egress boundary holds for it.

  The request carries the profile headers the caller signed, the content type of the body and the two unsigned convenience headers, the event type and the attempt number (WH-9). An event type that cannot be written as a header value is left out rather than sent mangled; nothing depends on it.

  Besides the signature an endpoint may ask for mutual TLS (`:client_certificate` in its configuration) or for an OAuth2 client credentials token (`:oauth2`). The token request goes through the egress boundary as well, with the same policy and limits (WH-43). The token is never held here: the caller passes `:token_cache`, a function that is given the fetch function and returns the token of this endpoint, fetching only when it has none that is still valid. The token and the client secret are wrapped values and appear in no failure and in no receipt (WH-19).

  Options: `:policy` (the egress policy) and the options of `Relay.Webhooks.Egress.request/3`; `:token_cache` when the endpoint uses OAuth2; `:user_agent`.
  """

  @behaviour Relay.Webhooks.Destination

  alias Relay.Redacted
  alias Relay.Webhooks.Destination
  alias Relay.Webhooks.Egress
  alias Relay.Webhooks.Profile

  @egress_options [
    :connect_timeout_ms,
    :total_timeout_ms,
    :max_response_bytes,
    :dns_timeout_ms,
    :resolver,
    :transport,
    :ca_certificates,
    :proxy
  ]
  @user_agent "Suiss-Webhooks/1"
  @header_safe ~r/\A[\x21-\x7E]{1,256}\z/
  @kept_classes [:invalid, :blocked]

  @type oauth2 :: %{
          required(:token_url) => String.t(),
          required(:client_id) => String.t(),
          required(:client_secret) => Redacted.t(),
          optional(:scope) => String.t()
        }
  @type config :: %{
          required(:url) => String.t(),
          optional(:client_certificate) => Egress.Transport.client_certificate() | nil,
          optional(:oauth2) => oauth2() | nil
        }
  @type fetched :: {:ok, Redacted.t(), pos_integer() | nil} | {:error, Destination.failure()}
  @type token_cache :: ((-> fetched()) -> {:ok, Redacted.t()} | {:error, Destination.failure()})

  # WH-17
  # WH-9
  @impl Relay.Webhooks.Destination
  def deliver(%{url: url} = config, prepared, opts) when is_list(opts) do
    policy = Keyword.fetch!(opts, :policy)

    case authorization(config, policy, opts) do
      {:ok, authorization} ->
        headers = headers(prepared, authorization, opts)
        request = %{method: "POST", url: url, headers: headers, body: prepared.body}
        policy |> Egress.request(request, egress_options(config, opts)) |> answer()

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp answer({:ok, response}), do: {:ok, Map.put(response, :kind, :http)}
  defp answer({:error, error}), do: {:error, error}

  defp egress_options(config, opts) do
    certificate = Map.get(config, :client_certificate)
    Keyword.take(opts, @egress_options) ++ [client_certificate: certificate]
  end

  # WH-9
  defp headers(prepared, authorization, opts) do
    fixed = [
      {"content-type", prepared.content_type},
      {"user-agent", Keyword.get(opts, :user_agent, @user_agent)}
    ]

    fixed ++ prepared.headers ++ convenience(prepared) ++ authorization
  end

  defp convenience(%{type: type, attempt: attempt}) do
    headers = Profile.unsigned_headers(type, attempt)
    if Regex.match?(@header_safe, type), do: headers, else: tl(headers)
  end

  # WH-17
  # WH-19
  defp authorization(%{oauth2: %{} = oauth2}, policy, opts) do
    cache = Keyword.fetch!(opts, :token_cache)

    case cache.(fn -> fetch_token(oauth2, policy, opts) end) do
      {:ok, token} -> {:ok, [{"authorization", "Bearer " <> Redacted.expose(token)}]}
      {:error, failure} -> {:error, failure}
    end
  end

  defp authorization(_config, _policy, _opts), do: {:ok, []}

  # WH-43
  defp fetch_token(oauth2, policy, opts) do
    request = %{
      method: "POST",
      url: oauth2.token_url,
      headers: token_headers(oauth2),
      body: token_body(oauth2)
    }

    case Egress.request(policy, request, Keyword.take(opts, @egress_options)) do
      {:ok, %{status: 200, truncated: false} = response} -> token(response)
      {:ok, response} -> {:error, unavailable("token_endpoint_refused", response)}
      {:error, %{class: class} = error} when class in @kept_classes -> {:error, error}
      {:error, error} -> {:error, unavailable("token_endpoint_" <> error.reason, error)}
    end
  end

  defp token_headers(%{client_id: id, client_secret: secret}) do
    pair = URI.encode_www_form(id) <> ":" <> URI.encode_www_form(Redacted.expose(secret))

    [
      {"content-type", "application/x-www-form-urlencoded"},
      {"accept", "application/json"},
      {"authorization", "Basic " <> Base.encode64(pair)}
    ]
  end

  defp token_body(%{scope: scope}) when is_binary(scope) and scope != "",
    do: URI.encode_query([{"grant_type", "client_credentials"}, {"scope", scope}])

  defp token_body(_oauth2), do: URI.encode_query([{"grant_type", "client_credentials"}])

  defp token(response) do
    case Jason.decode(response.body) do
      {:ok, %{"access_token" => token} = body} when is_binary(token) and token != "" ->
        bearer(body, token, response)

      _other ->
        {:error, unavailable("token_response_invalid", response)}
    end
  end

  defp bearer(body, token, response) do
    if bearer?(body),
      do: {:ok, Redacted.wrap(token), lifetime(body)},
      else: {:error, unavailable("token_type_unsupported", response)}
  end

  defp bearer?(%{"token_type" => type}) when is_binary(type),
    do: String.downcase(type, :ascii) == "bearer"

  defp bearer?(%{"token_type" => _other}), do: false
  defp bearer?(_body), do: true

  defp lifetime(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0, do: seconds
  defp lifetime(_body), do: nil

  defp unavailable(reason, %{duration_ms: duration_ms, address: address}),
    do: %{class: :credentials, reason: reason, duration_ms: duration_ms, address: address}
end
