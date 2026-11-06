defmodule Relay.Channels.Fcm.Bearer do
  @moduledoc """
  The OAuth access token of one FCM connection (TN-30): `Relay.Channels.Push.Fcm.Auth` with Workload Identity Federation or a service account assertion signed in the key store, cached in the connection's state for its lifetime less one minute. The token endpoints are called through `Relay.Channels.http_request/1`.
  """

  @behaviour Relay.Channels.Push.H2.Auth

  alias Relay.Channels.Push.Common
  alias Relay.Channels.Push.Fcm.Auth

  @timeout_ms 10_000

  @impl Relay.Channels.Push.H2.Auth
  def init(_config), do: %{}

  # TN-30
  @impl Relay.Channels.Push.H2.Auth
  def authorization(%{source: source} = config, cache, now) do
    opts = [http: &http/1, subject_token: fn -> subject(config) end]

    case Auth.access_token(source, cache, now, opts) do
      {:ok, token, cache} -> {:ok, "Bearer " <> Relay.Redacted.expose(token), cache}
      {:error, error} -> {:error, error, cache}
    end
  end

  defp subject(%{subject_token: nil}), do: {:error, :missing}
  defp subject(%{subject_token: token}), do: {:ok, Relay.Redacted.expose(token)}

  defp http(request) do
    case Common.http(Relay.Channels.Fcm, request, @timeout_ms) do
      {:ok, %{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
