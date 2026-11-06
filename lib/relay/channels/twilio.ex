defmodule Relay.Channels.Twilio do
  @moduledoc """
  The Twilio SMS and voice adapter (CH-3, CH-48, CH-50), a thin client of Twilio's REST API 2010-04-01 on Req, without Twilio's SDK; its declaration is `priv/channels/twilio/`. Twilio is not a BTK-authorized route: a `+90` number is never sent through it (CH-51).

    * The provider account's `settings.account_sid` and the credential (the auth token) authenticate with HTTP Basic. A sender identity whose value starts with `MG` is a Messaging Service, any other value the `From` number or sender id.
    * SMS: `POST /Accounts/{sid}/Messages.json`. Twilio has no encoding field: with `SmartEncoded` off it sends GSM-7 text as GSM-7 and any other text as UCS-2, which is exactly the encoding Relay names (CH-48), so the catalogue lists only `GSM7` and `UCS2`. The validity (`ValidityPeriod`, at most 36000 seconds) follows the channel time to live (CH-9).
    * Voice: `POST /Accounts/{sid}/Calls.json` with TwiML that reads the text once in the content's language; the call status callback reports `completed`.
    * `settings.status_callback_url` is sent as the `StatusCallback`, with the provider idempotency key in its `key` query parameter, which the signed callback brings back. Twilio has no idempotency key and no client message id, so an uncertain call is never sent again on its own (`no_auto_retry`, T-28).
    * A failure answers with Twilio's error `code` (`21211`), or `http:<status>` without one. A delivery report carries its `ErrorCode`; a call report its status `call:<status>` (`reports/3`, verified with `X-Twilio-Signature` on the raw body).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Adapter
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request

  @base "https://api.twilio.com/2010-04-01/Accounts/"
  @max_validity_s 36_000
  @call_failures ~w(busy no-answer failed canceled)

  @impl Relay.Channels.Adapter
  def provider, do: "twilio"

  @impl Relay.Channels.Adapter
  def channels, do: ["sms", "voice"]

  # CH-48
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    sid = to_string(ProviderHttp.setting(request, "account_sid"))
    {resource, form} = form(request)

    opts = [
      method: :post,
      url: @base <> URI.encode(sid) <> resource,
      form: form ++ callback(request),
      auth: {:basic, sid <> ":" <> ProviderHttp.secret(request)}
    ]

    case ProviderHttp.call(opts, request.timeout_ms) do
      {:ok, %Req.Response{status: status, body: %{"sid" => id}}} when status in [200, 201] ->
        {:accepted, %{provider_message_id: id}}

      {:ok, %Req.Response{} = response} ->
        raw = raw(response.status, response.body)
        {:rejected, Map.put(raw, :retry_after_ms, ProviderHttp.retry_after_ms(response))}

      other ->
        other
    end
  end

  defp form(%Request{channel: "voice"} = request) do
    language = language(request.content)
    text = escape(ProviderHttp.text(request))
    twiml = ~s(<Response><Say language="#{language}">#{text}</Say></Response>)

    {"/Calls.json",
     [
       {"To", Relay.Redacted.expose(request.target.value)},
       {"From", ProviderHttp.sender(request)},
       {"Twiml", twiml}
     ]}
  end

  defp form(request) do
    {"/Messages.json",
     [
       {"To", Relay.Redacted.expose(request.target.value)},
       sender(ProviderHttp.sender(request)),
       {"Body", ProviderHttp.text(request)},
       {"SmartEncoded", "false"}
     ] ++ validity(request.ttl_s)}
  end

  defp sender("MG" <> _rest = service), do: {"MessagingServiceSid", service}
  defp sender(from), do: {"From", from}

  defp validity(ttl) when is_integer(ttl) and ttl > 0,
    do: [{"ValidityPeriod", Integer.to_string(min(ttl, @max_validity_s))}]

  defp validity(_ttl), do: []

  defp callback(request) do
    case ProviderHttp.setting(request, "status_callback_url") do
      url when is_binary(url) and url != "" -> [{"StatusCallback", keyed(url, request)}]
      _none -> []
    end
  end

  defp keyed(url, request) do
    uri = URI.parse(url)
    query = Map.put(URI.decode_query(uri.query || ""), "key", request.idempotency_key)
    URI.to_string(%{uri | query: URI.encode_query(query)})
  end

  defp language(%{"language" => language}) when is_binary(language) and language != "",
    do: language

  defp language(_content), do: "en-US"

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp raw(status, %{"code" => code}) when is_integer(code),
    do: %{code: Integer.to_string(code), status: status}

  defp raw(status, _body), do: %{code: "http:" <> Integer.to_string(status), status: status}

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"report" => params}) do
    case report(params).result do
      {:rejected, raw} -> raw
      _other -> %{code: "pending"}
    end
  end

  def decode(%{"status" => status, "body" => body}), do: raw(status, body)

  # T-40
  # TN-35
  @impl Relay.Channels.Adapter
  def reports(body, headers, opts) when is_binary(body) do
    key = Keyword.fetch!(opts, :key)
    url = Keyword.fetch!(opts, :url)

    with :ok <- Relay.Channels.verify_twilio(key, url, body, headers) do
      query = URI.decode_query(URI.parse(url).query || "")
      report = Map.put(report(URI.decode_query(body)), :correlation, query["key"])
      {:ok, [report]}
    end
  end

  # CH-10
  @doc "Reads one Twilio status callback: a message's `delivered` is delivered, `undelivered` and `failed` a failure with its `ErrorCode` (`status:<status>` without one), any other status pending; a call's `completed` is delivered and `busy`, `no-answer`, `failed` and `canceled` a failure `call:<status>`."
  @spec report(map()) :: Adapter.report()
  def report(%{"CallSid" => sid} = params) do
    status = params["CallStatus"]

    result =
      cond do
        status == "completed" -> {:delivered, %{}}
        status in @call_failures -> {:rejected, %{code: "call:" <> status}}
        true -> :pending
      end

    %{
      provider_message_id: sid,
      result: result,
      channel: "voice",
      detail: Map.take(params, ["CallDuration", "Duration", "SequenceNumber"])
    }
  end

  def report(%{} = params) do
    result =
      case {params["MessageStatus"], params["ErrorCode"]} do
        {"delivered", _code} -> {:delivered, %{}}
        {status, code} when status in ["undelivered", "failed"] -> failed(status, code)
        _pending -> :pending
      end

    %{
      provider_message_id: params["MessageSid"],
      result: result,
      channel: "sms",
      detail: Map.take(params, ["RawDlrDoneDate"])
    }
  end

  defp failed(status, code) when code in [nil, ""],
    do: {:rejected, %{code: "status:" <> status}}

  defp failed(_status, code), do: {:rejected, %{code: code}}
end
