defmodule Relay.Channels.Netgsm do
  @moduledoc """
  The Netgsm SMS adapter (CH-3, CH-51, CH-53), a thin client of Netgsm's REST v2 API on Req; its declaration is `priv/channels/netgsm/`. Netgsm is a Turkish operator, so it is a BTK-authorized route for `+90` numbers.

    * The provider account's `settings.usercode` and the credential (the API password) authenticate with HTTP Basic; the sender identity's value is the header (`msgheader`).
    * A `security` message on the OTP product (`product: "otp"`) goes to `/sms/rest/v2/otp`, Netgsm's prioritized OTP service with its own credit; every other message to `/sms/rest/v2/send` (CH-53).
    * The encoding is named on every send (CH-48): `GSM7_TR` is `encoding: "TR"`; Netgsm has no UCS-2 value, so its catalogue lists only `GSM7` and `GSM7_TR`, and while its Turkish single shift is unverified Turkish text is refused before the call (CH-75).
    * A commercial (`marketing`) message is sent with the İYS filter `11`; any other with `0`.
    * The validity end (`stopdate`, Turkish time, `ddMMyyyyHHmm`) follows the channel time to live (CH-9).
    * A failure answers with a code in the body: `send:<code>`, `otp:<code>`, or `http:<status>` without one. A delivery report row's status is `dlr:<status>` (`report/1`).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Adapter
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request

  @base "https://api.netgsm.com.tr"
  @istanbul_s 3 * 3600

  @impl Relay.Channels.Adapter
  def provider, do: "netgsm"

  @impl Relay.Channels.Adapter
  def channels, do: ["sms"]

  # CH-48
  # CH-53
  @impl Relay.Channels.Adapter
  def deliver(%Request{} = request) do
    {path, body} = payload(request)
    user = to_string(ProviderHttp.setting(request, "usercode"))
    auth = {:basic, user <> ":" <> ProviderHttp.secret(request)}
    opts = [method: :post, url: @base <> path, json: body, auth: auth]

    case ProviderHttp.call(opts, request.timeout_ms) do
      {:ok, response} -> answer(response, request.product)
      other -> other
    end
  end

  defp payload(%Request{product: "otp"} = request) do
    {"/sms/rest/v2/otp",
     %{
       "msgheader" => ProviderHttp.sender(request),
       "msg" => ProviderHttp.text(request),
       "no" => ProviderHttp.digits(request)
     }}
  end

  defp payload(request) do
    message = %{"msg" => ProviderHttp.text(request), "no" => ProviderHttp.digits(request)}

    body =
      %{
        "msgheader" => ProviderHttp.sender(request),
        "messages" => [message],
        "iysfilter" => if(request.message_class == "marketing", do: "11", else: "0")
      }
      |> put_encoding(request.encoding)
      |> put_stop(request.ttl_s)

    {"/sms/rest/v2/send", body}
  end

  defp put_encoding(body, "GSM7_TR"), do: Map.put(body, "encoding", "TR")
  defp put_encoding(body, _gsm7), do: body

  defp put_stop(body, ttl) when is_integer(ttl) and ttl > 0 do
    stop = DateTime.add(Relay.Clock.utc_now(), ttl + @istanbul_s, :second)
    Map.put(body, "stopdate", Calendar.strftime(stop, "%d%m%Y%H%M"))
  end

  defp put_stop(body, _ttl), do: body

  defp answer(%Req.Response{status: 200, body: %{"code" => code} = body}, _product)
       when code in ["00", "0"] do
    id = body["jobid"] || body["jobId"]
    {:accepted, %{provider_message_id: to_string(id)}}
  end

  defp answer(%Req.Response{} = response, product),
    do: {:rejected, raw(response.status, response.body, product, response)}

  defp raw(status, %{"code" => code}, product, response) when is_binary(code) do
    prefix = if product == "otp", do: "otp:", else: "send:"
    %{code: prefix <> code, status: status, retry_after_ms: retry_after(response)}
  end

  defp raw(status, _body, _product, response),
    do: %{code: "http:#{status}", status: status, retry_after_ms: retry_after(response)}

  defp retry_after(nil), do: nil
  defp retry_after(response), do: ProviderHttp.retry_after_ms(response)

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"report" => row}) do
    case report(row).result do
      {:rejected, raw} -> raw
      _other -> %{code: "dlr:" <> to_string(row["status"])}
    end
  end

  def decode(%{"status" => status, "body" => body} = response) do
    product = get_in(response, ["body", "product"])
    raw(status, body, product, nil)
  end

  # CH-10
  @doc "Reads one row of Netgsm's delivery report (`/sms/rest/v2/report`): status `1` is delivered, `0` pending and any other a failure `dlr:<status>`."
  @spec report(map()) :: Adapter.report()
  def report(%{} = row) do
    result =
      case to_string(row["status"]) do
        "1" -> {:delivered, %{}}
        "0" -> :pending
        status -> {:rejected, %{code: "dlr:" <> status, status: nil, detail: detail(row)}}
      end

    %{
      provider_message_id: to_string(row["jobid"] || ""),
      result: result,
      channel: "sms",
      detail: detail(row)
    }
  end

  defp detail(row), do: Map.take(row, ["errorCode", "operator", "msglen"])
end
