defmodule EsuissRelay.Client do
  @moduledoc """
  The Relay server API client.

      client =
        EsuissRelay.Client.new(
          base_url: "https://relay.example.com",
          credentials:
            EsuissRelay.Credentials.AccessClient.new(
              token_endpoint: "https://access.example.com/oauth2/token",
              client_id: "...",
              client_secret: "...",
              resource: "..."
            )
        )

      {:ok, waitpoint} = EsuissRelay.Api.get_waitpoint(client, "wp_...")

  Every request carries the API version this SDK was generated for (`Relay-Version`), so a new
  SDK release never changes the behaviour of a pinned version. Mutating requests get an
  `Idempotency-Key` that stays the same across every retry of the call. Only errors Relay marks
  `retryable` are retried, after `Retry-After` when it is given and otherwise with exponential
  backoff and full jitter.

  Options of `new/1`:

    * `:base_url` - the region's base address (required; https, or http on localhost)
    * `:credentials` - an `EsuissRelay.Credentials` implementation (required)
    * `:max_retries` - retries after the first attempt (default 3)
    * `:base_delay_ms` - first backoff ceiling (default 500)
    * `:max_delay_ms` - largest backoff ceiling (default 8_000)
    * `:max_retry_after_s` - the longest `Retry-After` the client waits for (default 60)
    * `:timeout` - per attempt, in milliseconds (default 30_000)
    * `:transport` - `{module, state}` of an `EsuissRelay.Transport` (default `:httpc`)
    * `:sleep`, `:random`, `:random_bytes`, `:clock`, `:monotonic` - injectable time and
      randomness, mainly for tests

  Request options accepted by every `EsuissRelay.Api` function: `:idempotency_key`,
  `:if_match`, `:beta`, `:headers`, `:content_type`, `:max_retries`, `:timeout` and, for
  operations whose body is optional, `:body`. `raw: true` returns an `EsuissRelay.Response`
  with the status, the headers and whether the answer was replayed. Every other key is a query
  parameter.
  """

  alias EsuissRelay.Credentials
  alias EsuissRelay.DpopKey
  alias EsuissRelay.Error
  alias EsuissRelay.Generated.Version
  alias EsuissRelay.Operation
  alias EsuissRelay.Page
  alias EsuissRelay.Response

  @sdk_version "0.1.0"

  @enforce_keys [:base_url, :credentials]
  defstruct [
    :base_url,
    :credentials,
    transport: {EsuissRelay.Transport.Httpc, nil},
    max_retries: 3,
    base_delay_ms: 500,
    max_delay_ms: 8_000,
    max_retry_after_s: 60,
    timeout: 30_000,
    sleep: &Process.sleep/1,
    random: &:rand.uniform/0,
    random_bytes: &:crypto.strong_rand_bytes/1,
    clock: &EsuissRelay.Client.unix_now/0,
    monotonic: &EsuissRelay.Client.monotonic_now/0
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          credentials: Credentials.t(),
          transport: {module(), term()},
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          max_retry_after_s: non_neg_integer(),
          timeout: pos_integer(),
          sleep: (non_neg_integer() -> any()),
          random: (-> float()),
          random_bytes: (pos_integer() -> binary()),
          clock: (-> integer()),
          monotonic: (-> integer())
        }

  @type result :: {:ok, term()} | {:error, Error.t()}

  @request_options [
    :idempotency_key,
    :if_match,
    :beta,
    :headers,
    :content_type,
    :max_retries,
    :timeout,
    :body,
    :raw
  ]

  @doc "A new client. See the module documentation for the options."
  @spec new(keyword()) :: t()
  def new(opts) do
    base_url = opts |> Keyword.fetch!(:base_url) |> String.trim_trailing("/")

    if not secure?(base_url) do
      raise ArgumentError, "base_url must be an https URL, got: #{inspect(base_url)}"
    end

    struct!(__MODULE__, Keyword.put(opts, :base_url, base_url))
  end

  defp secure?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1", "::1"] -> true
      _other -> false
    end
  end

  @doc "The API version this SDK sends on every request."
  @spec api_version() :: String.t()
  def api_version, do: Version.api_version()

  @doc "The `User-Agent` of the SDK."
  @spec user_agent() :: String.t()
  def user_agent, do: "esuiss-relay-elixir/#{@sdk_version} (api #{Version.api_version()})"

  # API-10
  # API-38
  # API-49
  # API-55
  # X-29
  @doc """
  Calls one operation. `path_values` fill the path parameters in order; `body` is the request
  body of an operation whose body is required (`nil` otherwise).
  """
  @spec call(t(), Operation.t(), [term()], term(), keyword()) :: result()
  def call(%__MODULE__{} = client, %Operation{} = operation, path_values, body, opts) do
    {request_opts, query_opts} = Keyword.split(opts, @request_options)

    if operation.paginated and query_opts[:starting_after] != nil and
         query_opts[:ending_before] != nil do
      raise ArgumentError, "starting_after and ending_before together (both_cursors)"
    end

    body = if operation.body == :required, do: body, else: Keyword.get(request_opts, :body)

    if operation.body == :required and is_nil(body) do
      raise ArgumentError, "#{operation.id} needs a request body"
    end

    request = %{
      method: operation.method,
      url: url(client, operation, path_values, query_opts),
      headers: headers(client, operation, request_opts, body),
      body: encode(body),
      timeout: Keyword.get(request_opts, :timeout, client.timeout)
    }

    max = Keyword.get(request_opts, :max_retries, client.max_retries)

    with {:ok, response} <- run(client, operation, request, 0, max) do
      decode(client, operation, path_values, opts, response)
    end
  end

  defp url(client, operation, path_values, query_opts) do
    if length(path_values) != length(operation.path_params) do
      raise ArgumentError, "#{operation.id} takes #{length(operation.path_params)} path values"
    end

    path =
      operation.path_params
      |> Enum.zip(path_values)
      |> Enum.reduce(operation.path, fn {name, value}, path ->
        String.replace(path, "{#{name}}", URI.encode(to_string(value), &URI.char_unreserved?/1))
      end)

    case query(operation, query_opts) do
      [] -> client.base_url <> path
      pairs -> client.base_url <> path <> "?" <> URI.encode_query(pairs, :rfc3986)
    end
  end

  defp query(operation, query_opts) do
    known = Enum.map(operation.query, &elem(&1, 0))

    case Keyword.keys(query_opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "#{operation.id} takes no option #{inspect(unknown)}"
    end

    Enum.flat_map(operation.query, fn {name, kind, required} ->
      case {Keyword.get(query_opts, name), required} do
        {nil, true} -> raise ArgumentError, "#{operation.id} needs the query parameter #{name}"
        {nil, false} -> []
        {value, _required} -> [{Atom.to_string(name), encode_query(kind, value)}]
      end
    end)
  end

  defp encode_query(:string_array, values) when is_list(values),
    do: Enum.map_join(values, ",", &to_string/1)

  defp encode_query(_kind, value), do: to_string(value)

  defp headers(client, operation, request_opts, body) do
    [
      {"accept", "application/json"},
      {"relay-version", Version.api_version()},
      {"user-agent", user_agent()}
    ]
    |> add("content-type", body != nil && content_type(operation, request_opts))
    |> add("idempotency-key", idempotency_key(client, operation, request_opts))
    |> add("if-match", if_match(operation, request_opts))
    |> add("relay-beta", beta(Keyword.get(request_opts, :beta)))
    |> Kernel.++(extra_headers(Keyword.get(request_opts, :headers, [])))
  end

  defp add(headers, _name, value) when value in [nil, false], do: headers
  defp add(headers, name, value), do: headers ++ [{name, value}]

  defp content_type(operation, request_opts),
    do: Keyword.get(request_opts, :content_type) || operation.content_type || "application/json"

  # API-10
  defp idempotency_key(_client, %Operation{idempotency: :none}, _request_opts), do: nil

  defp idempotency_key(client, _operation, request_opts),
    do: Keyword.get_lazy(request_opts, :idempotency_key, fn -> new_key(client) end)

  @doc "A new random idempotency key (a version 4 UUID), never derived from content."
  @spec new_key(t()) :: String.t()
  def new_key(%__MODULE__{random_bytes: random_bytes}) do
    <<a::48, _::4, b::12, _::2, c::62>> = random_bytes.(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    [<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defp if_match(operation, request_opts) do
    case {operation.if_match, Keyword.get(request_opts, :if_match)} do
      {:required, nil} -> raise ArgumentError, "#{operation.id} needs the :if_match option"
      {_requirement, value} -> value
    end
  end

  defp beta(nil), do: nil
  defp beta(features) when is_list(features), do: Enum.join(features, ",")
  defp beta(feature) when is_binary(feature), do: feature

  defp extra_headers(headers),
    do: Enum.map(headers, fn {name, value} -> {String.downcase(to_string(name)), value} end)

  defp encode(nil), do: nil
  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: JSON.encode!(body)

  defp run(client, operation, request, retry, max) do
    with {:ok, authorized} <- authorize(client, request) do
      case transport(client, authorized) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, response} ->
          error = Error.from_transport(response, client.clock.())
          decision = decide(client, retry + 1, max, error.retryable, error.retry_after)
          again(client, operation, request, {retry, max}, decision, {:error, error})

        {:error, reason} ->
          safe =
            operation.method == :get or List.keymember?(request.headers, "idempotency-key", 0)

          decision = decide(client, retry + 1, max, safe, nil)

          again(
            client,
            operation,
            request,
            {retry, max},
            decision,
            {:error, Error.connection(reason)}
          )
      end
    end
  end

  defp again(client, operation, request, {retry, max}, {:retry, wait}, _failure) do
    client.sleep.(wait)
    run(client, operation, request, retry + 1, max)
  end

  defp again(_client, _operation, _request, _retries, {:stop, _reason}, failure), do: failure

  # X-29
  # API-38
  # API-49
  @doc """
  Whether retry number `retry` (counted from 1) of a call with at most `max` retries happens,
  and after how many milliseconds: `{:retry, ms}`, or `{:stop, reason}` with `:not_retryable`,
  `:retries_exhausted` or `:retry_after_too_long`. `outcome` is `{:response, response}` or
  `:network_error`. The wait is `Retry-After` (delta seconds or HTTP-date), else the problem's
  `retry_after`, else full jitter under `min(max_delay_ms, base_delay_ms * 2^(retry - 1))`.
  """
  @spec retry_decision(
          t(),
          pos_integer(),
          non_neg_integer(),
          {:response, EsuissRelay.Transport.response()} | :network_error
        ) ::
          {:retry, non_neg_integer()}
          | {:stop, :not_retryable | :retries_exhausted | :retry_after_too_long}
  def retry_decision(client, retry, max, :network_error),
    do: decide(client, retry, max, true, nil)

  def retry_decision(client, retry, max, {:response, response}) do
    error = Error.from_transport(response, client.clock.())
    decide(client, retry, max, error.retryable, error.retry_after)
  end

  defp decide(_client, _retry, _max, false, _retry_after), do: {:stop, :not_retryable}

  defp decide(_client, retry, max, true, _retry_after) when retry > max,
    do: {:stop, :retries_exhausted}

  defp decide(client, _retry, _max, true, seconds) when is_integer(seconds) do
    if seconds <= client.max_retry_after_s,
      do: {:retry, seconds * 1000},
      else: {:stop, :retry_after_too_long}
  end

  defp decide(client, retry, _max, true, nil) do
    ceiling = min(client.max_delay_ms, client.base_delay_ms * Integer.pow(2, retry - 1))
    {:retry, floor(client.random.() * ceiling)}
  end

  defp authorize(client, request) do
    with {:ok, token, key} <- Credentials.token(client.credentials, client) do
      proof =
        DpopKey.proof(
          key,
          request.method |> Atom.to_string() |> String.upcase(),
          request.url,
          token,
          nil,
          client.clock.(),
          client.random_bytes.(16)
        )

      {:ok,
       %{
         request
         | headers: [{"authorization", "DPoP " <> token}, {"dpop", proof} | request.headers]
       }}
    end
  end

  @doc "Sends one request through the client's transport."
  @spec transport(t(), EsuissRelay.Transport.request()) ::
          {:ok, EsuissRelay.Transport.response()} | {:error, term()}
  def transport(%__MODULE__{transport: {module, state}}, request),
    do: module.request(state, request)

  @doc "The value of a header, matched without regard to case; `nil` when absent."
  @spec header([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp decode(client, operation, path_values, opts, response) do
    body = decode_body(client, operation, path_values, opts, response)

    if Keyword.get(opts, :raw, false),
      do: {:ok, Response.new(response, body)},
      else: {:ok, body}
  end

  defp decode_body(_client, %Operation{response: :none}, _path_values, _opts, _response), do: nil

  defp decode_body(_client, %Operation{response: :text}, _path_values, _opts, response),
    do: response.body

  defp decode_body(_client, _operation, _path_values, _opts, %{body: ""}), do: nil

  defp decode_body(client, %Operation{paginated: true} = operation, path_values, opts, response),
    do:
      Page.new(
        client,
        operation,
        path_values,
        Keyword.delete(opts, :raw),
        JSON.decode!(response.body)
      )

  defp decode_body(_client, _operation, _path_values, _opts, response),
    do: JSON.decode!(response.body)

  @doc false
  @spec unix_now() :: integer()
  def unix_now, do: System.os_time(:second)

  @doc false
  @spec monotonic_now() :: integer()
  def monotonic_now, do: System.monotonic_time(:millisecond)
end
