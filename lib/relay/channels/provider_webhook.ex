defmodule Relay.Channels.ProviderWebhook do
  @moduledoc """
  Verifies and reads the delivery report and event webhook of an SMS or e-mail provider account (WH-49, T-40, CH-47). Verification runs on the raw body, before it is parsed, with the provider's declared method and the shared verifiers of `Relay.Channels.Inbound`, in constant time:

    * `twilio`, `infobip` and `verimor`: the adapter's `c:Relay.Channels.Adapter.reports/3` (Twilio's `X-Twilio-Signature` over the callback URL, Infobip's HMAC-SHA256, Verimor's token in the callback URL).
    * `postmark`: the basic credentials Postmark sends from the webhook URL, compared with the secret `user:password` (declared unverifiable).
    * `sendgrid`: the ECDSA P-256 signature of the signed Event Webhook over the timestamp and the body.
    * `mailgun`: the HMAC-SHA256 of the body's own timestamp and token with the webhook signing key (declared unverifiable).

  A verified body becomes its items: `{:report, report}` for an SMS or voice delivery report that is not pending, `{:email, event}` for an e-mail event that names a delivery and is not ignored. Nothing here reads a clock or the database.
  """

  alias Relay.Channels.Email.Event
  alias Relay.Channels.Inbound

  @reports %{
    "infobip" => Relay.Channels.Infobip,
    "twilio" => Relay.Channels.Twilio,
    "verimor" => Relay.Channels.Verimor
  }
  @email ["mailgun", "postmark", "sendgrid"]
  @sendgrid_signature "x-twilio-email-event-webhook-signature"
  @sendgrid_timestamp "x-twilio-email-event-webhook-timestamp"

  @type item :: {:report, Relay.Channels.Adapter.report()} | {:email, Event.t()}
  @type request :: %{
          required(:body) => binary(),
          required(:headers) => Inbound.headers(),
          required(:url) => String.t(),
          required(:token) => String.t() | nil,
          required(:now) => DateTime.t()
        }
  @type reason ::
          :missing_header | :bad_signature | :stale_timestamp | :bad_timestamp | :invalid_body

  @doc "The providers whose webhook is read here."
  @spec providers() :: [String.t(), ...]
  def providers, do: Enum.sort(Map.keys(@reports) ++ @email)

  # WH-49
  # T-40
  # CH-47
  @doc "Verifies a webhook request of `provider` with its verification secret `key` and reads its items; see the module documentation."
  @spec read(String.t(), Relay.Redacted.t(), request()) :: {:ok, [item()]} | {:error, reason()}
  def read(provider, key, %{body: body} = request) when is_map_key(@reports, provider) do
    adapter = Map.fetch!(@reports, provider)
    opts = [key: key, url: request.url, token: request.token, now: request.now]

    case adapter.reports(body, request.headers, opts) do
      {:ok, reports} ->
        {:ok, for(%{result: result} = r <- reports, result != :pending, do: {:report, r})}

      {:error, reason} ->
        {:error, reason(reason)}
    end
  end

  def read("postmark", key, request) do
    expected = Relay.Redacted.wrap("Basic " <> Base.encode64(Relay.Redacted.expose(key)))

    with :ok <- Inbound.secret_token(expected, request.headers, "authorization"),
         do: {:ok, email("postmark", request.body)}
  end

  def read("sendgrid", key, request) do
    opts = [header: @sendgrid_signature, timestamp_header: @sendgrid_timestamp, now: request.now]

    with :ok <- Inbound.ecdsa(key, request.body, request.headers, opts),
         do: {:ok, email("sendgrid", request.body)}
  end

  def read("mailgun", key, request) do
    with {:ok, %{} = body} <- Jason.decode(request.body),
         :ok <- Relay.Channels.Mailgun.verify(key, body, request.now) do
      {:ok, email("mailgun", body)}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason(reason)}
      _invalid -> {:error, :invalid_body}
    end
  end

  defp email(provider, body) do
    for %Event{type: type, delivery_id: <<_::128>>} = event <-
          Relay.Channels.email_events(provider, body),
        type != :ignored,
        do: {:email, event}
  end

  defp reason(:missing_signature), do: :missing_header
  defp reason(reason), do: reason
end
