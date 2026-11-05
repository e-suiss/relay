defmodule Relay.Channels.Verimor do
  @moduledoc """
  The Verimor SMS and voice adapter (CH-3, CH-48, CH-51, CH-56), a thin client of Verimor's SMS API v2 and of its Bulutsantralim automatic call campaigns on Req; its declaration is `priv/channels/verimor/`. Verimor is a Turkish operator and a BTK-authorized route for `+90` numbers.

    * SMS: `POST /v2/send.json` with the account's `settings.username` and the credential (the API password). The encoding is named on every send (CH-48): `datacoding` `0` for `GSM7`, `1` for `GSM7_TR` and `2` for `UCS2`. The provider idempotency key is the message's custom id (`messages[].id`) and the campaign's `custom_id`, so an uncertain send is looked up with `GET /v2/status?custom_id=` (`query/1`, T-28). The validity (`valid_for`) follows the channel time to live, between one minute and 48 hours (CH-9). A commercial (`marketing`) message is flagged `is_commercial` with the İYS recipient type `BIREYSEL`.
    * Voice (`otp_oob`, CH-56): one call campaign per delivery, `POST /ivr_campaigns.json` with the credential as the API key, the sender identity's number as the caller id (`cli`) and the text read in the content's language (`tr-TR` by default). The billing unit is the answered call.
    * A failure answers with its error name or status: `send:<NAME>`, `voice:<status>` or `http:<status>`. A delivery report is `dlr:<STATUS>` and a call report `call:<status>`.
    * Neither webhook is signed: the callback URL carries a secret token checked in constant time, a compensating control whose authenticity is declared unverifiable (`reports/3`).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Adapter
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request

  @sms "https://sms.verimor.com.tr"
  @voice "https://api.bulutsantralim.com"
  @datacoding %{"GSM7" => "0", "GSM7_TR" => "1", "UCS2" => "2"}
  @languages ~w(tr-TR en-US ar-XA)
  @pending ~w(SENDING WAITING SENT)
  @max_valid_s 48 * 3600

  @impl Relay.Channels.Adapter
  def provider, do: "verimor"

  @impl Relay.Channels.Adapter
  def channels, do: ["sms", "voice"]

  # CH-48
  # CH-56
  @impl Relay.Channels.Adapter
  def deliver(%Request{channel: "voice"} = request) do
    body = %{
      "call_type" => "ivr",
      "name" => request.idempotency_key,
      "phone_list" => [
        %{
          "phone" => ProviderHttp.digits(request),
          "phrase" => ProviderHttp.text(request),
          "lang" => language(request.content)
        }
      ],
      "cli" => ProviderHttp.sender(request),
      "timeout_target" => "timeout",
      "is_commercial" => false
    }

    opts = [
      method: :post,
      url: @voice <> "/ivr_campaigns.json",
      params: [key: ProviderHttp.secret(request)],
      json: body
    ]

    case ProviderHttp.call(opts, request.timeout_ms) do
      {:ok, response} -> answer(response, "voice:")
      other -> other
    end
  end

  def deliver(%Request{} = request) do
    case ProviderHttp.call(sms_options(request), request.timeout_ms) do
      {:ok, response} -> answer(response, "send:")
      other -> other
    end
  end

  defp sms_options(request) do
    commercial? = request.message_class == "marketing"

    message = %{
      "msg" => ProviderHttp.text(request),
      "dest" => ProviderHttp.digits(request),
      "id" => request.idempotency_key
    }

    body =
      %{
        "username" => to_string(ProviderHttp.setting(request, "username")),
        "password" => ProviderHttp.secret(request),
        "source_addr" => ProviderHttp.sender(request),
        "custom_id" => request.idempotency_key,
        "datacoding" => Map.get(@datacoding, request.encoding, "0"),
        "is_commercial" => commercial?,
        "messages" => [message]
      }
      |> put_valid_for(request.ttl_s)
      |> put_recipient_type(commercial?)

    [method: :post, url: @sms <> "/v2/send.json", json: body]
  end

  defp put_valid_for(body, ttl) when is_integer(ttl) and ttl > 0 do
    minutes = div(min(max(ttl, 60), @max_valid_s), 60)
    hours = div(minutes, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    rest = rem(minutes, 60) |> Integer.to_string() |> String.pad_leading(2, "0")
    Map.put(body, "valid_for", hours <> ":" <> rest)
  end

  defp put_valid_for(body, _ttl), do: body

  defp put_recipient_type(body, true), do: Map.put(body, "iys_recipient_type", "BIREYSEL")
  defp put_recipient_type(body, false), do: body

  defp language(%{"language" => language}) when language in @languages, do: language

  defp language(%{"language" => "en" <> _rest}), do: "en-US"
  defp language(%{"language" => "ar" <> _rest}), do: "ar-XA"
  defp language(_content), do: "tr-TR"

  defp answer(%Req.Response{status: 200, body: body}, _prefix) do
    {:accepted, %{provider_message_id: body |> to_string() |> String.trim()}}
  end

  defp answer(%Req.Response{} = response, prefix) do
    raw = raw(response.status, response.body, prefix)
    {:rejected, Map.put(raw, :retry_after_ms, ProviderHttp.retry_after_ms(response))}
  end

  defp raw(400, body, "send:") when is_binary(body) and body != "" do
    %{code: "send:" <> String.trim(body), status: 400}
  end

  defp raw(status, _body, "voice:") when status in [400, 401, 403],
    do: %{code: "voice:" <> Integer.to_string(status), status: status}

  defp raw(status, _body, _prefix),
    do: %{code: "http:" <> Integer.to_string(status), status: status}

  # T-28
  @impl Relay.Channels.Adapter
  def query(%Request{channel: "sms"} = request) do
    opts = [
      method: :get,
      url: @sms <> "/v2/status",
      params: [
        username: to_string(ProviderHttp.setting(request, "username")),
        password: ProviderHttp.secret(request),
        custom_id: request.idempotency_key
      ]
    ]

    case ProviderHttp.call(opts, request.timeout_ms) do
      {:ok, %Req.Response{status: 200, body: body}} -> queried(rows(body))
      {:ok, %Req.Response{status: 404}} -> :not_received
      _other -> :unavailable
    end
  end

  def query(_request), do: :unavailable

  defp rows(rows) when is_list(rows), do: rows
  defp rows(%{"messages" => rows}) when is_list(rows), do: rows
  defp rows(_body), do: []

  defp queried([]), do: :not_received

  defp queried([row | _]) do
    case sms_report(row).result do
      {:rejected, raw} -> {:rejected, raw}
      {:delivered, _info} -> {:accepted, %{provider_message_id: id(row)}}
      :pending -> {:accepted, %{provider_message_id: id(row)}}
    end
  end

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"report" => %{"channel" => "voice"} = row}), do: raw_of(call_report(row))
  def decode(%{"report" => row}), do: raw_of(sms_report(row))

  def decode(%{"status" => status, "body" => body} = response) do
    prefix = if response["channel"] == "voice", do: "voice:", else: "send:"
    raw(status, body, prefix)
  end

  defp raw_of(%{result: {:rejected, raw}}), do: raw
  defp raw_of(_report), do: %{code: "pending"}

  # CH-3
  # T-40
  @impl Relay.Channels.Adapter
  def reports(body, _headers, opts) when is_binary(body) do
    with :ok <- Relay.Channels.verify_url_token(Keyword.fetch!(opts, :key), opts[:token]) do
      parse(String.trim_leading(body))
    end
  end

  defp parse("[" <> _rest = body) do
    case Jason.decode(body) do
      {:ok, rows} when is_list(rows) -> {:ok, Enum.map(rows, &sms_report/1)}
      _invalid -> {:error, :invalid_body}
    end
  end

  defp parse(body), do: {:ok, [call_report(URI.decode_query(body))]}

  # CH-10
  @doc "Reads one Verimor SMS delivery report: `DELIVERED` is delivered, `SENDING`, `WAITING` and `SENT` (sent without an operator report) pending, and any other status a failure `dlr:<STATUS>`."
  @spec sms_report(map()) :: Adapter.report()
  def sms_report(%{} = row) do
    status = to_string(row["status"])

    result =
      cond do
        status == "DELIVERED" -> {:delivered, %{}}
        status in @pending -> :pending
        true -> {:rejected, %{code: "dlr:" <> status, status: nil}}
      end

    %{
      provider_message_id: id(row),
      result: result,
      channel: "sms",
      correlation: row["message_custom_id"],
      detail: Map.take(row, ["gsm_error", "credits", "size", "done_at"])
    }
  end

  # CH-56
  @doc "Reads one Verimor call campaign report: `Cevaplandı` (answered) is delivered and any other status a failure `call:<status>`."
  @spec call_report(map()) :: Adapter.report()
  def call_report(%{} = row) do
    status = to_string(row["status"])
    answered? = :unicode.characters_to_nfc_binary(status) == "Cevaplandı"
    result = if answered?, do: {:delivered, %{}}, else: {:rejected, %{code: "call:" <> status}}

    %{
      provider_message_id: string(row["ivr_campaign_id"]),
      result: result,
      channel: "voice",
      correlation: row["ivr_campaign_name"],
      detail: Map.take(row, ["call_uuid", "digit"])
    }
  end

  defp id(row), do: string(row["message_id"] || row["campaign_id"])

  defp string(nil), do: nil
  defp string(value), do: to_string(value)
end
