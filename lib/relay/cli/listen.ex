defmodule Relay.CLI.Listen do
  @moduledoc """
  `relay listen --forward-to <url>`: the local development tunnel. It polls the notifications of the environment created after the command started (`GET /v1/notifications`, operation `listNotifications`; `--workflow`, `--subscriber`, `--status`, `--interval`) and forwards each one as a JSON `POST` to the local URL, which must be on a loopback address. The tunnel lives only here: the Relay API has no customer-defined bridge URL and never calls a developer machine. The access token is never sent to the local URL, and a failed forward is reported without stopping the tunnel.
  """

  @behaviour Relay.CLI.Command

  alias Relay.CLI.Args
  alias Relay.CLI.Config
  alias Relay.CLI.Failure
  alias Relay.CLI.Feed
  alias Relay.CLI.HTTP
  alias Relay.CLI.Logs
  alias Relay.CLI.Output

  # X-33
  # API-64
  # WH-45
  @impl Relay.CLI.Command
  def run(ctx, %Args{opts: opts}) do
    with {:ok, url} <- forward_url(opts[:forward_to]),
         {:ok, interval_ms} <- Logs.interval_ms(opts) do
      Output.warn(ctx, "forwarding new notifications to #{url}; stop with Ctrl-C")
      handle = fn notifications -> Enum.each(notifications, &forward(ctx, url, &1)) end

      case Feed.follow(ctx, Logs.filters(opts), interval_ms, Feed.new(ctx.now.()), handle) do
        {:ok, summary} ->
          data = %{"polls" => summary.polls, "forwarded" => summary.notifications}
          {:ok, data, ["forwarded #{summary.notifications} notification(s)"]}

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

  defp forward(ctx, url, notification) do
    id = notification["id"]

    case HTTP.request(ctx, method: :post, url: url, json: notification) do
      {:ok, %{status: status}} ->
        data = %{"notification_id" => id, "status" => status}
        Output.item(ctx, "forwarded", data, "#{id} -> #{status}")

      {:error, reason} ->
        data = %{"notification_id" => id, "error" => reason}
        Output.item(ctx, "forward_failed", data, "#{id} -> failed: #{reason}")
    end
  end

  defp usage(message), do: {:error, Failure.new(:usage, "usage_error", message)}
end
