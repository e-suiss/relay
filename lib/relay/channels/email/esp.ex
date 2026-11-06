defmodule Relay.Channels.Email.Esp do
  @moduledoc """
  What the ESP adapters share (CH-3, T-40): one provider HTTP call through `Relay.Channels.http_request/1`, bounded by the request's timeout and never retried, the provider credential read from the secret backend for this call only (TN-26), and the reading of an HTTP answer into a raw code.

  A call that never reached the provider (no connection, unknown host) is `:not_sent`; one that may have reached it (a timeout, a connection closed mid-request) is `:uncertain` (T-28). The test environment adds its `Req` options (`config :relay, Relay.Channels.Email.Esp, req_options: [...]`), so no test reaches the network.
  """

  alias Relay.Channels.Adapter
  alias Relay.Channels.Email
  alias Relay.Channels.Request

  @key_store [:key_store_unavailable, :key_store_timeout, :key_store_protocol]
  @unreached [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :eaddrnotavail]
  @connect_ms 5_000

  @type answer :: {:ok, Req.Response.t()} | {:not_sent, String.t()} | {:uncertain, String.t()}

  # CH-9
  # T-26
  # T-28
  @doc "Sends one provider HTTP request for `request`, with its timeout; the body is not decoded."
  @spec call(Request.t(), keyword()) :: answer()
  def call(%Request{timeout_ms: timeout_ms}, opts) when is_list(opts), do: http(timeout_ms, opts)

  # CH-9
  # T-26
  @doc "Sends one provider HTTP request within `timeout_ms`; the body is not decoded."
  @spec http(pos_integer(), keyword()) :: answer()
  def http(timeout_ms, opts) when is_integer(timeout_ms) and is_list(opts) do
    opts =
      [
        receive_timeout: timeout_ms,
        connect_options: [timeout: min(timeout_ms, @connect_ms)],
        decode_body: false,
        compressed: false
      ]
      |> Keyword.merge(opts)
      |> Keyword.merge(test_options())

    case Relay.Channels.http_request(opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %{reason: reason}} when reason in @unreached ->
        {:not_sent, Atom.to_string(reason)}

      {:error, _exception} ->
        {:uncertain, "transport_error"}
    end
  end

  # CH-35
  # CH-38
  # CH-45
  @doc "Prepares the e-mail of a request (`Email.prepare/2`); a refusal is a rejection with its raw code, and an unavailable key store means nothing was sent."
  @spec prepare(Request.t(), keyword()) ::
          {:ok, Email.prepared()}
          | {:rejected, Adapter.raw()}
          | {:not_sent, String.t()}
  def prepare(%Request{} = request, opts \\ []) do
    case Email.prepare(request, opts) do
      {:ok, prepared} ->
        {:ok, prepared}

      {:error, %Relay.Error{code: code}} when code in @key_store ->
        {:not_sent, "key_store_unavailable"}

      {:error, %Relay.Error{} = error} ->
        refused(preparation_code(error))
    end
  end

  defp test_options do
    :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end

  # TN-26
  @doc "The provider credential of a request as a map of strings: the secret is a map or its JSON text."
  @spec credentials(Request.t()) :: {:ok, map()} | :error
  def credentials(%Request{credentials: credentials}), do: credential_map(credentials)

  # TN-26
  @doc "A redacted provider credential as a map of strings: the secret is a map or its JSON text."
  @spec credential_map(Relay.Redacted.t() | nil) :: {:ok, map()} | :error
  def credential_map(nil), do: :error

  def credential_map(credentials) do
    case Relay.Redacted.expose(credentials) do
      %{} = map ->
        {:ok, map}

      text when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{} = map} -> {:ok, map}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  @doc "A string field of a credential map."
  @spec secret(map(), String.t()) :: {:ok, String.t()} | :error
  def secret(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> :error
    end
  end

  @doc "The provider settings of an account under `key`, an empty map when there are none."
  @spec settings(Request.t(), String.t()) :: map()
  def settings(%Request{account: %{"settings" => %{} = settings}}, key) do
    case Map.get(settings, key) do
      %{} = provider -> provider
      _missing -> %{}
    end
  end

  def settings(%Request{}, _key), do: %{}

  # CH-9
  @doc "The provider's `Retry-After` of a response, in milliseconds."
  @spec retry_after_ms(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_ms(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _rest] -> Relay.Channels.retry_after_ms(value, Relay.Clock.utc_now())
      [] -> nil
    end
  end

  @doc "Decodes a JSON response body; anything else is an empty map."
  @spec json(Req.Response.t() | binary() | map()) :: map()
  def json(%Req.Response{body: body}), do: json(body)
  def json(%{} = body), do: body

  def json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  def json(_body), do: %{}

  # CH-7
  @doc "The raw code of an HTTP status without a more specific provider code: `http_<status>` for 4xx and `http_5xx` for every server error."
  @spec http_code(non_neg_integer()) :: String.t()
  def http_code(status) when status >= 500, do: "http_5xx"
  def http_code(status), do: "http_" <> Integer.to_string(status)

  @doc "A rejection of a response with a code."
  @spec rejected(Req.Response.t(), String.t()) :: {:rejected, Adapter.raw()}
  def rejected(%Req.Response{} = response, code) do
    raw = %{code: code, status: response.status, retry_after_ms: retry_after_ms(response)}
    {:rejected, Map.put(raw, :detail, %{})}
  end

  @doc "A rejection of a response by its HTTP status (`http_code/1`)."
  @spec status_rejected(Req.Response.t()) :: {:rejected, Adapter.raw()}
  def status_rejected(%Req.Response{status: status} = response),
    do: rejected(response, http_code(status))

  @doc "The local refusal of a request before any provider call, with its raw code."
  @spec refused(String.t()) :: {:rejected, Adapter.raw()}
  def refused(code), do: {:rejected, %{code: code, status: nil}}

  # CH-45
  # CH-35
  @doc "The raw code of an error of `Email.prepare/2`: `smtputf8_unsupported`, `sender_invalid` for a missing stream identity, `message_invalid` otherwise."
  @spec preparation_code(Relay.Error.t()) :: String.t()
  def preparation_code(%Relay.Error{code: :smtputf8_unsupported}), do: "smtputf8_unsupported"
  def preparation_code(%Relay.Error{code: :invalid_email_streams}), do: "sender_invalid"
  def preparation_code(%Relay.Error{}), do: "message_invalid"
end
