defmodule RelayWeb.Api.Response do
  @moduledoc """
  Writing API responses: JSON bodies in UTF-8 converted to the request's API version, RFC 9457 problems for errors (with the OAuth `error` member on the subscriber token exchange), the headers every API response carries (`Request-Id`, `Relay-Version`, HSTS, the rate limit headers) and idempotent execution with byte-for-byte replays.
  """

  import Plug.Conn

  require Logger

  alias Relay.Api.ErrorMap
  alias Relay.Api.Idempotency
  alias Relay.Api.Problem
  alias Relay.Api.Versions

  @json "application/json; charset=utf-8"
  @problem "application/problem+json; charset=utf-8"
  @unavailable [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error]
  @token_exchange "exchangeSubscriberToken"
  @no_oauth_error [:rate_limited, :internal_error, :service_unavailable, :upstream_timeout]

  # API-8
  # sobelow_skip ["XSS.SendResp"]
  @doc "Sends a JSON body, converted from the internal model to the request's API version."
  @spec json(Plug.Conn.t(), 100..599, map() | list()) :: Plug.Conn.t()
  def json(conn, status, body) do
    {status, headers, bytes} = encode(conn, status, body)

    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, bytes)
  end

  @doc "Encodes a JSON response as `{status, headers, body}` without sending it, for idempotent work."
  @spec encode(Plug.Conn.t(), 100..599, map() | list()) :: Idempotency.response()
  def encode(conn, status, body) do
    version = conn.assigns[:api_version] || Versions.latest()
    body = Versions.response(version, operation_id(conn), body)
    {status, [{"content-type", @json}], Jason.encode!(body)}
  end

  # API-36
  # API-38
  # API-47
  # sobelow_skip ["XSS.SendResp"]
  @doc "Sends the problem of an error, mapped to its API code, and halts."
  @spec problem(Plug.Conn.t(), Relay.Error.t()) :: Plug.Conn.t()
  def problem(conn, %Relay.Error{} = error) do
    {status, retry, body} = Problem.build(oauth(conn, ErrorMap.to_api(error)), context(conn))
    headers = if status == 401, do: [{"www-authenticate", challenge(body)}], else: []

    conn
    |> merge_resp_headers([{"content-type", @problem} | headers] ++ retry)
    |> send_resp(status, Jason.encode_to_iodata!(body))
    |> halt()
  end

  # API-45
  # API-79 (2)
  defp oauth(%{assigns: %{operation: %{id: @token_exchange}}}, %Relay.Error{} = error) do
    case oauth_error(error) do
      nil -> error
      code -> %{error | details: Map.put(error.details, :error, code)}
    end
  end

  defp oauth(_conn, error), do: error

  defp oauth_error(%Relay.Error{code: code}) when code in @no_oauth_error, do: nil

  defp oauth_error(%Relay.Error{code: code, details: details})
       when code in [:validation_failed, :unknown_field] do
    pointers = Enum.map(Map.get(details, :errors, []), &pointer/1)

    cond do
      "/grant_type" in pointers -> "unsupported_grant_type"
      "/scope" in pointers -> "invalid_scope"
      true -> "invalid_request"
    end
  end

  defp oauth_error(_error), do: "invalid_request"

  defp pointer(field_error), do: field_error[:pointer] || field_error["pointer"]

  # INV-2
  # API-51
  @doc "Answers an exception raised while serving an API request: a database that cannot serve is `service_unavailable`, anything else `internal_error`."
  @spec exception(Plug.Conn.t(), Exception.t(), Exception.stacktrace()) :: Plug.Conn.t()
  def exception(conn, exception, stacktrace) do
    Logger.error(Exception.format(:error, exception, stacktrace))

    code =
      if exception.__struct__ in @unavailable, do: :service_unavailable, else: :internal_error

    problem(conn, Relay.Error.new(code, "the request could not be served"))
  end

  # API-10
  # API-13
  # API-14
  # sobelow_skip ["XSS.SendResp"]
  @doc "Runs the work of an idempotent request (`Relay.Api.Idempotency.run/5`) and sends its response, or the stored one with `Idempotency-Replayed: true`."
  @spec idempotent(Plug.Conn.t(), Idempotency.work()) :: Plug.Conn.t()
  def idempotent(conn, work) do
    %{scope: scope, operation: operation, idempotency_key: key, raw_body: raw} = conn.assigns

    case Idempotency.run(scope, operation.endpoint, key, raw, work) do
      {:ok, {kind, {status, headers, body}}} ->
        replayed = if kind == :replayed, do: [{"idempotency-replayed", "true"}], else: []

        conn
        |> merge_resp_headers([{"idempotency-key", key} | headers] ++ replayed)
        |> send_resp(status, body)

      {:error, error} ->
        problem(conn, error)
    end
  end

  defp context(conn) do
    %{
      base_url: base_url(),
      instance: conn.request_path,
      request_id: conn |> get_resp_header("request-id") |> List.first()
    }
  end

  # API-73
  @doc "The region's base URL that problem types and error pages resolve on."
  @spec base_url() :: String.t()
  def base_url, do: RelayWeb.Endpoint.url()

  defp challenge(%{"code" => code}) when code in ["auth_invalid_token", "auth_expired_token"],
    do: ~s(Bearer realm="relay", error="invalid_token")

  defp challenge(_body), do: ~s(Bearer realm="relay")

  defp operation_id(%{assigns: %{operation: %{id: id}}}), do: id
  defp operation_id(_conn), do: ""
end
