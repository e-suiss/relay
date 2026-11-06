defmodule Relay.Channels.Messaging do
  @moduledoc """
  What the messaging channel adapters (Slack, Microsoft Teams, Telegram, Discord) share (CH-62, CH-3). They are thin `Req` adapters with no provider SDK: one adapter call is the provider call of `Relay.Channels.http_request/1`, which never retries and never follows a redirect; the provider's answer is reported as it came and the core classifies it.

    * `fields/1`: the rendered text fields of the channel cell. The renderer's canonical JSON carries them under `output`; `text` is the message, `title` an optional heading, and `action_url` with `action_label` an optional link button. A link button is the only action an adapter renders, so a card button can never act as an approval: an approval-type message links to the Access approval surface (CH-62, INV-29, AG-32).
    * `send/2`: one HTTP call bounded by the request's timeout, with the configured client options (`config :relay, Relay.Channels.Messaging, http: [...]`, a `Req.Test` plug in tests).
    * `transport/1`: a failed call is `{:not_sent, reason}` when no connection was made, so a retry is safe, and `{:uncertain, reason}` when the request may have reached the provider (T-28).
    * `retry_after_ms/1`: the provider's `Retry-After`, which the core always honours (CH-9).

  The provider message reference an adapter returns as `provider_message_id` names the conversation and the message, so a later message of the same subject updates it in place (CH-23).
  """

  alias Relay.Channels.Request

  @not_sent [
    :econnrefused,
    :nxdomain,
    :ehostunreach,
    :enetunreach,
    :eaddrnotavail,
    :connect_timeout
  ]

  @type fields :: %{optional(String.t()) => String.t()}

  # CH-62
  @doc "The rendered string fields of a request's content: the `output` of the renderer's canonical JSON, or a map of fields."
  @spec fields(map() | binary()) :: fields()
  def fields(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{} = decoded} -> fields(decoded)
      _invalid -> %{}
    end
  end

  def fields(%{"output" => %{} = output}), do: fields(output)

  def fields(%{} = content) do
    for {key, value} <- content, is_binary(key) and is_binary(value), into: %{}, do: {key, value}
  end

  # CH-62
  @doc "The message text: the title on its own line before the text, when there is one."
  @spec text(fields()) :: String.t()
  def text(fields) do
    [Map.get(fields, "title"), Map.get(fields, "text") || Map.get(fields, "body")]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  # CH-62
  # INV-29
  @doc "The link button of the fields, `{label, url}`, or `nil`: only an `https` URL is rendered as a button."
  @spec link(fields()) :: {String.t(), String.t()} | nil
  def link(%{"action_url" => "https://" <> _ = url} = fields) do
    label = Map.get(fields, "action_label")
    {if(blank?(label), do: url, else: label), url}
  end

  def link(_fields), do: nil

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  # T-26
  # CH-9
  @doc "Sends one provider HTTP request bounded by the request's timeout, with the configured client options merged."
  @spec send(Request.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def send(%Request{} = request, opts) do
    configured = Keyword.get(Application.get_env(:relay, __MODULE__, []), :http, [])

    opts
    |> Keyword.merge(configured)
    |> Keyword.merge(Keyword.get(opts, :http, []))
    |> Keyword.delete(:http)
    |> Keyword.put(:receive_timeout, request.timeout_ms)
    |> Keyword.put(:pool_timeout, request.timeout_ms)
    |> Keyword.put(:decode_body, false)
    |> Relay.Channels.http_request()
  end

  # T-28
  @doc "The result of a call that got no HTTP answer: `:not_sent` when no connection was made, otherwise `:uncertain`."
  @spec transport(Exception.t()) :: {:not_sent, String.t()} | {:uncertain, String.t()}
  def transport(%{reason: reason}) when reason in @not_sent, do: {:not_sent, reason_text(reason)}
  def transport(%{reason: {:tls_alert, _alert}}), do: {:not_sent, "tls_alert"}
  def transport(%{reason: reason}), do: {:uncertain, reason_text(reason)}
  def transport(_exception), do: {:uncertain, "transport"}

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(_reason), do: "transport"

  # CH-9
  @doc "The provider's `Retry-After` of a response in milliseconds, or `nil`."
  @spec retry_after_ms(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_ms(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> Relay.Channels.retry_after_ms(value, Relay.Clock.utc_now())
      [] -> nil
    end
  end

  # DS-11
  @doc "The `Retry-After` of a test vector's `response` (`headers.retry-after`, in seconds) in milliseconds, or `nil`."
  @spec vector_retry_after_ms(map()) :: non_neg_integer() | nil
  def vector_retry_after_ms(response) do
    case get_in(response, ["headers", "retry-after"]) do
      value when is_binary(value) -> Relay.Channels.retry_after_ms(value, Relay.Clock.utc_now())
      value -> seconds_ms(value)
    end
  end

  @doc "Seconds as milliseconds, for a provider that reports its wait in the body; `nil` for anything else."
  @spec seconds_ms(term()) :: non_neg_integer() | nil
  def seconds_ms(seconds) when is_integer(seconds) and seconds >= 0, do: seconds * 1000
  def seconds_ms(seconds) when is_float(seconds) and seconds >= 0, do: ceil(seconds * 1000)
  def seconds_ms(_seconds), do: nil

  @doc "Decodes a JSON response body; anything else is an empty map."
  @spec json(binary() | map() | nil) :: map()
  def json(%{} = body), do: body

  def json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{}
    end
  end

  def json(_body), do: %{}

  @doc "The raw code of an HTTP status without a provider code: `http_<status>`."
  @spec http_code(non_neg_integer()) :: String.t()
  def http_code(status), do: "http_" <> Integer.to_string(status)

  @doc "The exposed value of the request's target."
  @spec target(Request.t()) :: String.t()
  def target(%Request{target: %{value: value}}) do
    case Relay.Redacted.expose(value) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  @doc "The exposed credential of the request, or `nil`: a bot token, or the JSON identity of a bot (`Relay.Channels.Teams`)."
  @spec credential(Request.t()) :: String.t() | nil
  def credential(%Request{credentials: nil}), do: nil

  def credential(%Request{credentials: credentials}) do
    case Relay.Redacted.expose(credentials) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  # TN-26
  @doc "The bot token of the request's credential: the credential itself, or the `bot_token` of a channel identity's JSON secret; `nil` without one."
  @spec token(Request.t()) :: String.t() | nil
  def token(%Request{credentials: credentials}), do: bot_token(credentials)

  # TN-26
  @doc "The bot token of a provider credential: the credential itself, or the `bot_token` of a channel identity's JSON secret; `nil` without one."
  @spec bot_token(Relay.Redacted.t() | nil) :: String.t() | nil
  def bot_token(nil), do: nil

  def bot_token(credentials) do
    case Relay.Redacted.expose(credentials) do
      "{" <> _ = json -> json_token(json)
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp json_token(json) do
    case Jason.decode(json) do
      {:ok, %{"bot_token" => token}} when is_binary(token) and token != "" -> token
      _other -> nil
    end
  end

  # CH-23
  @doc "Splits a provider message reference `<conversation>:<message>` into its parts."
  @spec split_ref(String.t() | nil) :: {String.t(), String.t()} | nil
  def split_ref(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [conversation, message] when conversation != "" and message != "" -> {conversation, message}
      _invalid -> nil
    end
  end

  def split_ref(_ref), do: nil
end
