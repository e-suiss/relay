defmodule Relay.CLI.Listen do
  @moduledoc """
  `relay listen --forward-to <url>`: the local development tunnel (WH-45 (2), X-33). It polls the webhook events of the environment recorded after the command started (`GET /v1/webhook_events`, operation `listWebhookEvents`; `--event-type`, `--interval`) and forwards the CloudEvents envelope of each one as a `POST` to the local URL, which must be on a loopback address.

  A forwarded event carries the headers of the webhook profile, so the verification code of the local application runs unchanged: `webhook-id`, `webhook-timestamp` and a `v1` (HMAC-SHA256) `webhook-signature` over `<id>.<timestamp>.<body>`, and the unsigned `webhook-event-type` and `webhook-attempt`. The signing secret belongs to the listening session, never to an endpoint: `RELAY_LISTEN_SECRET` (`whsec_` and the base64 of at least 24 bytes) or, without it, a new one that is printed once when the command starts.

  The tunnel lives only here: the Relay API has no customer-defined bridge URL and never calls a developer machine. The access token is never sent to the local URL, and a failed forward is reported without stopping the tunnel.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Config
  alias Relay.CLI.Failure
  alias Relay.CLI.Feed
  alias Relay.CLI.HTTP
  alias Relay.CLI.Logs
  alias Relay.CLI.Output

  @events "/v1/webhook_events"
  @variable "RELAY_LISTEN_SECRET"
  @content_type "application/cloudevents+json; charset=utf-8"

  # X-33
  # API-64
  # WH-45
  @impl Relay.CLI.Command
  def run(ctx, %Args{opts: opts}) do
    with {:ok, url} <- forward_url(opts[:forward_to]),
         {:ok, interval_ms} <- Logs.interval_ms(opts),
         {:ok, secret} <- secret(ctx) do
      Output.warn(ctx, "forwarding webhook events to #{url}; stop with Ctrl-C")
      announce(ctx, secret)
      handle = fn events -> Enum.each(events, &forward(ctx, url, secret.key, &1)) end
      feed = Feed.new(ctx.now.(), @events)

      case Feed.follow(ctx, filters(opts), interval_ms, feed, handle) do
        {:ok, summary} ->
          data = %{"polls" => summary.polls, "forwarded" => summary.notifications}
          {:ok, data, ["forwarded #{summary.notifications} event(s)"]}

        {:error, _failure} = error ->
          error
      end
    end
  end

  # API-64
  @doc "Checks the `--forward-to` URL: http or https on a loopback address."
  @spec forward_url(String.t() | nil) :: {:ok, String.t()} | {:error, Failure.t()}
  def forward_url(nil),
    do: usage("listen needs --forward-to <url>, such as http://localhost:3000/hook")

  def forward_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
        if Config.loopback?(host),
          do: {:ok, url},
          else: usage("--forward-to must be a local address (localhost, 127.0.0.1 or ::1)")

      _other ->
        usage("--forward-to must be an http or https URL")
    end
  end

  defp filters(opts) do
    case opts[:event_type] do
      type when is_binary(type) -> [event_type: type]
      _none -> []
    end
  end

  # WH-4
  defp secret(ctx) do
    case Map.get(ctx.env, @variable) do
      nil -> {:ok, %{key: ctx.random_bytes.(32), generated?: true}}
      "whsec_" <> encoded -> configured(Base.decode64(encoded))
      _other -> malformed()
    end
  end

  defp configured({:ok, key}) when byte_size(key) >= 24, do: {:ok, %{key: key, generated?: false}}
  defp configured(_other), do: malformed()

  defp malformed, do: usage("#{@variable} must be whsec_ and the base64 of at least 24 bytes")

  defp announce(ctx, %{generated?: true, key: key}) do
    text = "whsec_" <> Base.encode64(key)
    Output.warn(ctx, "events are signed (v1) with the secret of this session: #{text}")
  end

  defp announce(ctx, %{generated?: false}),
    do: Output.warn(ctx, "events are signed (v1) with the secret in #{@variable}")

  # WH-4
  # WH-7 (1)
  # WH-9
  defp forward(ctx, url, key, %{"id" => id, "type" => type, "envelope" => %{} = envelope})
       when is_binary(id) and is_binary(type) do
    body = Jason.encode!(envelope)
    timestamp = Integer.to_string(DateTime.to_unix(ctx.now.()))
    signature = :crypto.mac(:hmac, :sha256, key, [id, ?., timestamp, ?., body])

    headers = [
      {"content-type", @content_type},
      {"webhook-id", id},
      {"webhook-timestamp", timestamp},
      {"webhook-signature", "v1," <> Base.encode64(signature)},
      {"webhook-event-type", type},
      {"webhook-attempt", "1"}
    ]

    case HTTP.request(ctx, method: :post, url: url, headers: headers, body: body) do
      {:ok, %{status: status}} ->
        data = %{"event_id" => id, "type" => type, "status" => status}
        Output.item(ctx, "forwarded", data, "#{id} #{type} -> #{status}")

      {:error, reason} ->
        data = %{"event_id" => id, "type" => type, "error" => reason}
        Output.item(ctx, "forward_failed", data, "#{id} #{type} -> failed: #{reason}")
    end
  end

  defp forward(_ctx, _url, _key, _event), do: :ok

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
