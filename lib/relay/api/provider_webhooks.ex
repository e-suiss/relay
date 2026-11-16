defmodule Relay.Api.ProviderWebhooks do
  @moduledoc """
  The inbound delivery report and event webhook of an SMS or e-mail provider account (`/inbound/v1/providers/{provider_account_id}`, WH-49): Twilio, Infobip, Verimor, Postmark, SendGrid and Mailgun. The path names the account; its tenant and environment come from the account, never from the request. The account's `settings.webhook_secret_ref_id` names the verification secret in the secret backend, read for this request only (TN-26): Twilio's auth token, Infobip's webhook secret, Verimor's callback token, Postmark's `user:password`, SendGrid's verification public key or Mailgun's webhook signing key.

  The request is verified on its raw body before anything is read (T-40); its events are committed as receipts with their processing jobs, and only then is the provider answered `200` (`Relay.Channels.Live.accept_provider_webhook/4`). A repeated event is acknowledged and counted, not processed again. An unknown, disabled or other provider's account is `404`, a request that does not verify `401`, a body that cannot be read `400`, and a receipt that could not be committed `503`, so the provider sends it again.
  """

  alias Relay.Channels.Live

  @unverified [:missing_header, :bad_signature, :stale_timestamp, :bad_timestamp]

  @type request :: %{
          required(:body) => binary(),
          required(:headers) => [{String.t(), String.t()}],
          required(:url) => String.t(),
          required(:token) => String.t() | nil
        }

  # WH-49
  # T-40
  # TN-26
  @doc "Verifies and records a provider webhook request of the account named by `account_text`; returns the HTTP status and the JSON body."
  @spec accept(String.t(), request()) :: {pos_integer(), map()}
  def accept(account_text, %{body: body} = request) when is_binary(body) do
    with {:ok, id} <- parse(account_text),
         {:ok, scope, account} <- account(id),
         {:ok, key} <- secret(scope, account) do
      request = Map.put(request, :now, Relay.Clock.utc_now())
      answer(Live.accept_provider_webhook(scope, account, key, request))
    end
  end

  defp answer({:ok, _counts}), do: {200, %{}}
  defp answer({:error, reason}) when reason in @unverified, do: unauthorized()
  defp answer({:error, :invalid_body}), do: {400, %{"error" => "malformed"}}
  defp answer({:error, _reason}), do: unavailable()

  defp parse(text) do
    case Relay.Id.parse(text) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> not_found()
    end
  end

  defp account(id) do
    case Relay.Channels.provider_webhook_account(id) do
      {:ok, scope, account} -> {:ok, scope, account}
      :not_found -> not_found()
    end
  end

  defp secret(scope, account) do
    with {:ok, ref_id} <- ref(get_in(account, ["settings", "webhook_secret_ref_id"])) do
      case Relay.Secrets.fetch(scope, ref_id) do
        {:ok, secret} -> {:ok, secret}
        {:error, _reason} -> unavailable()
      end
    end
  end

  defp ref(text) when is_binary(text) do
    case Relay.Id.parse(text) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> unauthorized()
    end
  end

  defp ref(_missing), do: unauthorized()

  defp not_found, do: {404, %{"error" => "not_found"}}
  defp unauthorized, do: {401, %{"error" => "unauthorized"}}
  defp unavailable, do: {503, %{"error" => "unavailable"}}
end
