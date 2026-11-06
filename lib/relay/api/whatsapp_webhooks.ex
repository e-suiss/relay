defmodule Relay.Api.WhatsappWebhooks do
  @moduledoc """
  The inbound webhook of a WhatsApp Cloud API provider account (`/v1/inbound/whatsapp/{provider_account_id}`, CH-60). The path names the account; its tenant and environment come from the account, never from the request. The account's settings name two secret references in the secret backend: `verify_token_ref_id`, the token of Meta's subscription check, and `app_secret_ref_id`, the Meta app secret `X-Hub-Signature-256` is checked with over the raw body before the body is read (CH-3, T-40). Both are read for this request only (TN-26). An unknown, disabled or other provider's account is `404`; a token or signature that does not match is `401` and nothing is applied.
  """

  alias Relay.Channels.Live

  # CH-60
  @doc "Answers Meta's subscription check of an account: the challenge as plain text when the token matches."
  @spec verify(String.t(), map()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def verify(account_text, params) do
    with {:ok, scope, account} <- account(account_text),
         {:ok, token} <- secret(scope, account, "verify_token_ref_id") do
      case Relay.Channels.whatsapp_challenge(params, token) do
        {:ok, challenge} -> {:ok, challenge}
        :error -> {:error, invalid()}
      end
    end
  end

  # CH-60
  # T-40
  @doc "Verifies and applies a notification of an account from its raw body and lower-case headers."
  @spec accept(String.t(), binary(), [{String.t(), String.t()}]) ::
          :ok | {:error, Relay.Error.t()}
  def accept(account_text, raw_body, headers) when is_binary(raw_body) do
    with {:ok, scope, account} <- account(account_text),
         {:ok, app_secret} <- secret(scope, account, "app_secret_ref_id") do
      case Live.whatsapp_inbound(scope, account, app_secret, raw_body, headers) do
        {:ok, _applied} -> :ok
        {:error, reason} when reason in [:missing_header, :bad_signature] -> {:error, invalid()}
        {:error, :invalid_body} -> {:error, malformed()}
        {:error, _reason} -> {:error, unavailable()}
      end
    end
  end

  defp account(text) do
    case parse(text) do
      {:ok, id} -> found(Relay.Channels.whatsapp_inbound_account(id))
      :error -> {:error, not_found()}
    end
  end

  defp found({:ok, scope, account}), do: {:ok, scope, account}
  defp found(:not_found), do: {:error, not_found()}

  defp parse(text) do
    case Relay.Id.parse(text) do
      {:ok, id} -> {:ok, id}
      {:error, _error} -> :error
    end
  end

  # TN-26
  defp secret(scope, account, key) do
    case parse(get_in(account, ["settings", key])) do
      {:ok, ref_id} -> fetched(Relay.Secrets.fetch(scope, ref_id))
      :error -> {:error, invalid()}
    end
  end

  defp fetched({:ok, secret}), do: {:ok, secret}
  defp fetched({:error, _reason}), do: {:error, unavailable()}

  defp not_found,
    do: Relay.Error.new(:provider_account_not_found, "no active WhatsApp account has this id")

  defp invalid, do: Relay.Error.new(:auth_invalid_token, "the webhook could not be verified")
  defp malformed, do: Relay.Error.new(:malformed_request, "the body is not a notification")

  defp unavailable do
    Relay.Error.new(:service_unavailable, "the webhook could not be applied", %{retry_after: 1})
  end
end
