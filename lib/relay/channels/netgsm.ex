defmodule Relay.Channels.Netgsm do
  @moduledoc """
  The Netgsm SMS adapter (CH-3, CH-51, CH-53), a thin client of Netgsm's REST v2 API on Req; its declaration is `priv/channels/netgsm/`. Netgsm is a Turkish operator, so it is a BTK-authorized route for `+90` numbers.

    * The provider account's `settings.usercode` and the credential (the API password) authenticate with HTTP Basic; the sender identity's value is the header (`msgheader`).
    * A `security` message on the OTP product (`product: "otp"`) goes to `/sms/rest/v2/otp`, Netgsm's prioritized OTP service with its own credit; every other message to `/sms/rest/v2/send` (CH-53).
    * The encoding is named on every send (CH-48): `GSM7_TR` is `encoding: "TR"`; Netgsm has no UCS-2 value, so its catalogue lists only `GSM7` and `GSM7_TR`, and while its Turkish single shift is unverified Turkish text is refused before the call (CH-75).
    * A commercial (`marketing`) message is sent with the İYS filter `11`; any other with `0`.
    * The validity end (`stopdate`, Turkish time, `ddMMyyyyHHmm`) follows the channel time to live (CH-9).
    * A failure answers with a code in the body: `send:<code>`, `otp:<code>`, or `http:<status>` without one. A delivery report row's status is `dlr:<status>` (`report/1`); the reconciliation reads the report of a send by its `jobid` (`delivery_status/1`, DS-48).
    * The settings check asks the balance (`/balance`) with the account's user code and password: Netgsm's code `30` (wrong credentials or no API access) is a credential mismatch (CH-14, CH-52).
  """

  @behaviour Relay.Channels.Adapter

  alias Relay.Channels.Adapter
  alias Relay.Channels.ProviderHttp
  alias Relay.Channels.Request
  alias Relay.Channels.SettingsCheck

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

  # CH-14
  # CH-52
  @impl Relay.Channels.Adapter
  def check_settings(%{account: account, credentials: credentials, timeout_ms: timeout_ms}) do
    case {get_in(account, ["settings", "usercode"]), credentials} do
      {user, secret} when is_binary(user) and user != "" and secret != nil ->
        body = %{"usercode" => user, "password" => Relay.Redacted.expose(secret), "stip" => 2}

        [method: :post, url: @base <> "/balance", json: body]
        |> ProviderHttp.call(timeout_ms)
        |> SettingsCheck.read(&balance/1)

      _missing ->
        SettingsCheck.credentials(nil)
    end
  end

  defp balance(%Req.Response{status: 200, body: body}) do
    case balance_code(body) do
      nil -> :ok
      "30" -> SettingsCheck.credentials("balance:30")
      code -> {:error, "balance:" <> code}
    end
  end

  defp balance(%Req.Response{status: status}), do: {:error, "http:#{status}"}

  defp balance_code(%{"code" => code}) when code in ["00", "0"], do: nil
  defp balance_code(%{"code" => code}), do: to_string(code)

  defp balance_code(body) when is_binary(body) do
    case String.trim(body) do
      "00" -> nil
      code -> if code =~ ~r/\A\d\d\z/, do: code
    end
  end

  defp balance_code(_body), do: nil

  # DS-22
  # DS-48
  @impl Relay.Channels.Adapter
  def delivery_status(%Request{provider_message_id: jobid} = request)
      when is_binary(jobid) and jobid != "" do
    user = to_string(ProviderHttp.setting(request, "usercode"))
    auth = {:basic, user <> ":" <> ProviderHttp.secret(request)}
    body = %{"jobids" => [jobid]}
    opts = [method: :post, url: @base <> "/sms/rest/v2/report", json: body, auth: auth]

    case ProviderHttp.call(opts, request.timeout_ms) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 406] ->
        reported(decoded(body))

      _other ->
        :unavailable
    end
  end

  def delivery_status(_request), do: :unavailable

  defp decoded(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _invalid -> %{}
    end
  end

  defp decoded(%{} = body), do: body
  defp decoded(_body), do: %{}

  defp reported(%{"code" => code, "jobs" => [_ | _] = jobs}) when code in ["00", "0"],
    do: {:ok, Enum.map(jobs, &report/1)}

  defp reported(%{"code" => code}) when code in ["00", "0"], do: :not_received
  defp reported(_body), do: :unavailable

  # DS-11
  @impl Relay.Channels.Adapter
  def decode(%{"report" => row}) do
    case report(row).result do
      {:rejected, raw} -> raw
      _other -> %{code: "dlr:" <> to_string(row["status"])}
    end
  end

  def decode(%{"status" => status, "body" => body}) do
    product = if is_map(body), do: body["product"]
    raw(status, body, product, nil)
  end

  # CH-10
  @doc "Reads one row of Netgsm's delivery report (`/sms/rest/v2/report`, `POST` with the `jobids` of the sends, also the reconciliation `delivery_status/1`): status `1` is delivered, `0` pending and any other a failure `dlr:<status>`."
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
