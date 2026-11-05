defmodule Relay.Channels.Infobip do
  @moduledoc """
  The Infobip SMS adapter (CH-3, CH-48), a thin client of Infobip's SMS API v3 on Req, without Infobip's SDK; its declaration is `priv/channels/infobip/`. Infobip is not a BTK-authorized route here: a `+90` number is never sent through it (CH-51).

    * The provider account's `settings.base_url` is the account's own Infobip host (`<id>.api.infobip.com`), checked before every call; the credential is the API key (`Authorization: App <key>`).
    * `POST /sms/3/messages`. The encoding is named on every send (CH-48): `GSM7_TR` is `language.languageCode: TR` with `singleShift`, `GSM7` and `UCS2` are `languageCode: NONE` with transliteration off, which Infobip sends in the encoding the text needs. The provider idempotency key is the destination's `messageId`, and the `callbackData` carries it again for the delivery reports; an uncertain send is looked up with `GET /sms/3/logs?messageId=` (`query/1`, T-28). The validity follows the channel time to live (CH-9), and `settings.webhook_url` receives the delivery reports.
    * A rejected message answers with its status name `status:<NAME>`, an API error with `http:<status>`. A delivery report is `status:<NAME>` (`reports/3`, verified with the HMAC-SHA256 `X-Hub-Signature` of the raw body).
    * A host that is not an Infobip API host is refused with `config:base_url`, which has no mapping and so raises the alarm (CH-8).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Adapter
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request

  @host ~r/\A[a-z0-9]+\.api(-[a-z0-9]+)?\.infobip\.com\z/
  @max_validity_s 48 * 3600
  @accepted ~w(PENDING ACCEPTED DELIVERED)

  @impl Relay.Channels.Adapter
  def provider, do: "infobip"

  @impl Relay.Channels.Adapter
  def channels, do: ["sms"]

  # CH-48
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    with {:ok, base} <- base(request) do
      opts = [
        method: :post,
        url: base <> "/sms/3/messages",
        headers: [{"authorization", "App " <> ProviderHttp.secret(request)}],
        json: %{"messages" => [message(request)]}
      ]

      case ProviderHttp.call(opts, request.timeout_ms) do
        {:ok, %Req.Response{status: 200, body: body}} -> sent(body)
        {:ok, %Req.Response{} = response} -> {:rejected, raw(response)}
        other -> other
      end
    end
  end

  defp base(request) do
    host = to_string(ProviderHttp.setting(request, "base_url"))

    if Regex.match?(@host, host),
      do: {:ok, "https://" <> host},
      else: {:rejected, %{code: "config:base_url", status: nil}}
  end

  defp message(request) do
    %{
      "sender" => ProviderHttp.sender(request),
      "destinations" => [
        %{"to" => ProviderHttp.digits(request), "messageId" => request.idempotency_key}
      ],
      "content" => %{
        "text" => ProviderHttp.text(request),
        "transliteration" => "NONE",
        "language" => language(request.encoding)
      },
      "webhooks" => webhooks(request)
    }
    |> put_validity(request.ttl_s)
  end

  defp language("GSM7_TR"), do: %{"languageCode" => "TR", "singleShift" => true}
  defp language(_encoding), do: %{"languageCode" => "NONE"}

  defp webhooks(request) do
    callback = %{"callbackData" => request.idempotency_key}

    case ProviderHttp.setting(request, "webhook_url") do
      url when is_binary(url) and url != "" -> Map.put(callback, "delivery", %{"url" => url})
      _none -> callback
    end
  end

  defp put_validity(message, ttl) when is_integer(ttl) and ttl > 0 do
    validity = %{"amount" => min(ttl, @max_validity_s), "timeUnit" => "SECONDS"}
    Map.put(message, "options", %{"validityPeriod" => validity})
  end

  defp put_validity(message, _ttl), do: message

  defp sent(%{"messages" => [%{"status" => %{"groupName" => group} = status} = sent | _]}) do
    if group in @accepted,
      do: {:accepted, %{provider_message_id: sent["messageId"]}},
      else: {:rejected, %{code: "status:" <> to_string(status["name"]), status: 200}}
  end

  defp sent(_body), do: {:rejected, %{code: "http:200", status: 200}}

  defp raw(%Req.Response{status: status} = response) do
    %{
      code: "http:" <> Integer.to_string(status),
      status: status,
      retry_after_ms: ProviderHttp.retry_after_ms(response)
    }
  end

  # T-28
  @impl Relay.Channels.Adapter
  def query(%Request{} = request) do
    with {:ok, base} <- base(request),
         {:ok, %Req.Response{status: 200, body: body}} <- logs(base, request) do
      case body do
        %{"results" => [row | _]} -> logged(report(row))
        %{"results" => []} -> :not_received
        _other -> :unavailable
      end
    else
      _unavailable -> :unavailable
    end
  end

  defp logs(base, request) do
    opts = [
      method: :get,
      url: base <> "/sms/3/logs",
      headers: [{"authorization", "App " <> ProviderHttp.secret(request)}],
      params: [messageId: request.idempotency_key]
    ]

    ProviderHttp.call(opts, request.timeout_ms)
  end

  defp logged(%{result: {:rejected, raw}}), do: {:rejected, raw}
  defp logged(%{provider_message_id: id}), do: {:accepted, %{provider_message_id: id}}

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"report" => row}) do
    case report(row).result do
      {:rejected, raw} -> raw
      _other -> %{code: "pending"}
    end
  end

  def decode(%{"status" => status}), do: %{code: "http:" <> Integer.to_string(status)}

  # T-40
  # TN-35
  @impl Relay.Channels.Adapter
  def reports(body, headers, opts) when is_binary(body) do
    key = Keyword.fetch!(opts, :key)

    with :ok <- signed(key, body, headers),
         {:ok, %{"results" => rows}} when is_list(rows) <- Jason.decode(body) do
      {:ok, Enum.map(rows, &report/1)}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_body}
    end
  end

  defp signed(key, body, headers) do
    hex = [header: "x-hub-signature"]

    case Relay.Channels.verify_hmac(key, body, headers, hex) do
      :ok -> :ok
      {:error, _hex} -> Relay.Channels.verify_hmac(key, body, headers, [encoding: :base64] ++ hex)
    end
  end

  # CH-10
  @doc "Reads one Infobip delivery report or log row: the `DELIVERED` group is delivered, `PENDING` and `ACCEPTED` pending, and any other group a failure `status:<NAME>`, with the price and the error kept as detail."
  @spec report(map()) :: Adapter.report()
  def report(%{} = row) do
    status = row["status"] || %{}
    code = "status:" <> to_string(status["name"])

    result =
      case status["groupName"] do
        "DELIVERED" -> {:delivered, %{}}
        group when group in ["PENDING", "ACCEPTED"] -> :pending
        _failed -> {:rejected, %{code: code, status: nil}}
      end

    %{
      provider_message_id: row["messageId"],
      result: result,
      channel: "sms",
      correlation: row["callbackData"],
      detail: Map.take(row, ["price", "error", "messageCount", "doneAt"])
    }
  end
end
