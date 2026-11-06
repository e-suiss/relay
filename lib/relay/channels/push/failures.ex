defmodule Relay.Channels.Push.Failures do
  @moduledoc """
  Reads the raw provider code of a push response (CH-7, CH-8, CH-71). An adapter decides nothing: it reports the code this module reads, and the failure class, condition and event code come from the adapter's declared mapping in `priv/channels/<provider>/errors.json`, with a test vector for every code in `vectors.json` beside it (`Relay.ChannelDeclarations`). A code without a mapping is `unknown`; it is never guessed.

  The codes:

    * APNs: `<status>/<reason>`, or `<status>` when the body names no reason;
    * FCM HTTP v1: the `FcmError` `errorCode`, else `rpc:<google.rpc status>`, else `<status>`;
    * HMS Push Kit: the result `code` of the body, else `<status>`;
    * Web Push and UnifiedPush (RFC 8030): `<status>`.

  A 2xx response is `:accepted`, which is never a delivery (CH-32); an HMS 2xx answer is accepted only with the success code `80000000`.
  """

  @providers [:apns, :fcm, :hms, :web_push]
  @fcm_error "type.googleapis.com/google.firebase.fcm.v1.FcmError"
  @hms_success "80000000"

  @type provider :: :apns | :fcm | :hms | :web_push

  @typedoc "An HTTP response; the body is raw or decoded JSON, the headers lower case."
  @type response :: %{
          required(:status) => pos_integer(),
          required(:body) => binary() | map() | nil,
          optional(:headers) => [{String.t(), String.t()}]
        }

  @typedoc "The raw failure an adapter reports (`c:Relay.Channels.Adapter.deliver/1`)."
  @type raw :: %{
          code: String.t(),
          status: pos_integer(),
          retry_after_ms: non_neg_integer() | nil,
          timestamp: DateTime.t() | nil,
          detail: map()
        }

  @doc "The providers whose responses this module reads."
  @spec providers() :: [provider(), ...]
  def providers, do: @providers

  # CH-7
  # CH-8
  # CH-11
  # CH-32
  @doc "Reads a provider response at `now`: `:accepted` or the raw failure with its code, the `Retry-After` delay (CH-9) and, for an APNs 410, the time the token became invalid (CH-11)."
  @spec read(provider(), response(), DateTime.t()) :: :accepted | {:rejected, raw()}
  def read(provider, %{status: status} = response, %DateTime{} = now)
      when provider in @providers do
    body = decode(Map.get(response, :body))

    if accepted?(provider, status, body) do
      :accepted
    else
      {:rejected,
       %{
         code: code(provider, status, body),
         status: status,
         retry_after_ms: retry_after(Map.get(response, :headers, []), now),
         timestamp: unregistered_at(provider, status, body),
         detail: %{}
       }}
    end
  end

  # DS-11
  @doc "The raw code of a response, as a test vector's `response` (`status`, `body`) states it."
  @spec code(provider(), map()) :: String.t()
  def code(provider, %{"status" => status} = response) when provider in @providers,
    do: code(provider, status, decode(response["body"]))

  defp accepted?(:hms, status, body) when status in 200..299,
    do: is_map(body) and body["code"] == @hms_success

  defp accepted?(_provider, status, _body), do: status in 200..299

  defp code(:apns, status, %{"reason" => reason}) when is_binary(reason) and reason != "",
    do: Integer.to_string(status) <> "/" <> reason

  defp code(:fcm, status, %{"error" => %{} = error}) do
    cond do
      code = error_code(error["details"]) -> code
      is_binary(error["status"]) -> "rpc:" <> error["status"]
      true -> Integer.to_string(status)
    end
  end

  defp code(:hms, _status, %{"code" => code}) when is_binary(code) and code != @hms_success,
    do: code

  defp code(_provider, status, _body), do: Integer.to_string(status)

  defp error_code(details) when is_list(details), do: Enum.find_value(details, &fcm_error/1)
  defp error_code(_details), do: nil

  defp fcm_error(%{"@type" => @fcm_error, "errorCode" => code}) when is_binary(code), do: code
  defp fcm_error(_detail), do: nil

  defp unregistered_at(:apns, 410, %{"timestamp" => ms}) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> at
      {:error, _reason} -> nil
    end
  end

  defp unregistered_at(_provider, _status, _body), do: nil

  defp retry_after(headers, now) do
    case List.keyfind(headers, "retry-after", 0) do
      {_name, value} -> Relay.Channels.Timeouts.retry_after_ms(value, now)
      nil -> nil
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode(body), do: body
end
