defmodule Relay.CLI.Client do
  @moduledoc """
  Relay API client of the command line tool. Each call carries the Access token of the API client of its environment and, when configured, `Relay-Version`. A `POST`, `PUT`, `PATCH` or `DELETE` carries a fresh `Idempotency-Key`, the same on every retry of that call. Only a problem marked `retryable: true` is retried, at most three times, after its `Retry-After` (or 1, 2 and 4 seconds) with up to 20 % jitter; a call whose token expired is repeated once with a new token. Any other answer that is not 2xx becomes a failure that keeps the problem.
  """

  alias Relay.CLI.Config
  alias Relay.CLI.Context
  alias Relay.CLI.Failure
  alias Relay.CLI.HTTP
  alias Relay.CLI.Token

  @mutating [:post, :put, :patch, :delete]
  @max_retries 3
  @max_delay_ms 60_000
  @max_pages 100

  @type option :: {:params, keyword()} | {:json, term()} | {:headers, [{String.t(), String.t()}]}

  # API-65
  # API-49
  # API-52
  @doc "Calls the Relay API as the API client of `environment` (`:params`, `:json` and extra `:headers`)."
  @spec call(Context.t(), Config.environment(), atom(), String.t(), [option()]) ::
          {:ok, HTTP.response()} | {:error, Failure.t()}
  def call(%Context{} = ctx, environment, method, path, opts \\ []) do
    headers =
      [{"accept", "application/json"}]
      |> put_header("relay-version", ctx.config.api_version)
      |> put_header("idempotency-key", if(method in @mutating, do: idempotency_key(ctx)))

    request =
      [method: method, url: ctx.config.api_url <> path]
      |> Keyword.merge(Keyword.take(opts, [:params, :json]))
      |> Keyword.put(:headers, headers ++ Keyword.get(opts, :headers, []))

    attempt(ctx, environment, request, 0, false)
  end

  # API-56
  @doc "Reads every page of a list operation, following `next_cursor` while `has_more` is true."
  @spec list_all(Context.t(), Config.environment(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Failure.t()}
  def list_all(%Context{} = ctx, environment, path, params \\ []),
    do: pages(ctx, environment, path, params, [], 1)

  @doc "Encodes one path segment."
  @spec segment(String.t() | integer()) :: String.t()
  def segment(value) when is_integer(value), do: Integer.to_string(value)
  def segment(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc "The failure of a 2xx answer whose body is not what the operation returns."
  @spec unexpected_body() :: Failure.t()
  def unexpected_body,
    do: Failure.new(:unexpected, "unexpected_response", "Relay answered with an unexpected body")

  defp pages(ctx, environment, path, params, acc, count) do
    case call(ctx, environment, :get, path, params: params) do
      {:ok, %{body: %{"data" => data} = body}} when is_list(data) ->
        next_page(ctx, environment, path, params, acc ++ data, count, body)

      {:ok, _response} ->
        {:error, unexpected_body()}

      {:error, _failure} = error ->
        error
    end
  end

  defp next_page(ctx, environment, path, params, acc, count, body) do
    case body do
      %{"has_more" => true, "next_cursor" => cursor}
      when is_binary(cursor) and count < @max_pages ->
        params = Keyword.put(params, :starting_after, cursor)
        pages(ctx, environment, path, params, acc, count + 1)

      _last ->
        {:ok, acc}
    end
  end

  defp attempt(ctx, environment, request, retries, renewed?) do
    with {:ok, token} <- Token.fetch(ctx, environment) do
      bearer = {"authorization", "Bearer " <> Relay.Redacted.expose(token)}

      case HTTP.request(ctx, Keyword.update!(request, :headers, &[bearer | &1])) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, response} ->
          again(ctx, environment, request, response, retries, renewed?)

        {:error, reason} ->
          message = "Relay is unreachable: " <> reason
          {:error, Failure.new(:unavailable, "connection_failed", message)}
      end
    end
  end

  defp again(ctx, environment, request, response, retries, renewed?) do
    cond do
      expired?(response) and not renewed? ->
        Token.forget(environment)
        attempt(ctx, environment, request, retries, true)

      retryable?(response) and retries < @max_retries ->
        backoff(ctx, environment, request, response, retries, renewed?)

      true ->
        {:error, Failure.from_response(response)}
    end
  end

  defp backoff(ctx, environment, request, response, retries, renewed?) do
    delay = delay_ms(response, retries)

    if delay <= @max_delay_ms do
      ctx.sleep.(delay + jitter(ctx, delay))
      attempt(ctx, environment, request, retries + 1, renewed?)
    else
      {:error, Failure.from_response(response)}
    end
  end

  defp jitter(ctx, delay),
    do: rem(:binary.decode_unsigned(ctx.random_bytes.(2)), div(delay, 5) + 1)

  defp expired?(%{status: 401, body: %{"code" => "auth_expired_token"}}), do: true
  defp expired?(_response), do: false

  defp retryable?(%{body: %{"retryable" => true}}), do: true
  defp retryable?(_response), do: false

  defp delay_ms(response, retries) do
    header = seconds(HTTP.header(response, "retry-after"))
    body = seconds(response.body["retry_after"])
    (header || body || Integer.pow(2, retries)) * 1000
  end

  defp seconds(value) when is_integer(value) and value >= 0, do: value

  defp seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds
      _other -> nil
    end
  end

  defp seconds(_value), do: nil

  defp idempotency_key(ctx),
    do: "relay-cli-" <> Base.url_encode64(ctx.random_bytes.(18), padding: false)

  defp put_header(headers, _name, nil), do: headers
  defp put_header(headers, name, value), do: headers ++ [{name, value}]
end
