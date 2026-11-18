defmodule RelayWeb.PreviewSandboxController do
  @moduledoc """
  The page of the sandboxed preview origin (TP-24, TP-39). It answers only on the configured preview host, which is never Relay's own host: on any other host, or without a configured one, every link is `404`, so rendered HTML never shares an origin with the API or the console. A known link answers the HTML as an inert document: its policy forbids scripts, forms, plugins, frames and every connection, puts the page in a `sandbox` with an opaque origin and lets only Relay's own origin frame it; images and fonts load over HTTPS or as data. The console shows the page in an `iframe` with an empty `sandbox` attribute. An unknown or expired link is `404` and an unreachable Valkey `503`. Nothing is cached and the link is never sent on as a referrer.
  """

  use RelayWeb, :controller

  alias Relay.Api.PreviewSandbox

  # TP-39
  @doc "Answers the HTML behind a preview link on the preview host."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    if sandbox_host?(conn.host),
      do: page(conn, PreviewSandbox.fetch(token)),
      else: send_resp(conn, 404, "")
  end

  defp sandbox_host?(host) do
    configured = PreviewSandbox.host()
    own = RelayWeb.Endpoint.config(:url)[:host]
    configured != nil and configured != own and String.downcase(host) == configured
  end

  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, {:ok, html}) do
    conn
    |> put_resp_content_type("text/html")
    |> merge_resp_headers(headers())
    |> send_resp(200, html)
  end

  defp page(conn, {:error, :not_found}), do: send_resp(conn, 404, "")

  defp page(conn, {:error, :unavailable}),
    do: conn |> put_resp_header("retry-after", "1") |> send_resp(503, "")

  # TP-39
  @doc "The headers of a sandboxed preview page."
  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    [
      {"content-security-policy", policy()},
      {"cache-control", "no-store"},
      {"referrer-policy", "no-referrer"},
      {"x-content-type-options", "nosniff"},
      {"x-robots-tag", "noindex"},
      {"cross-origin-opener-policy", "same-origin"}
    ]
  end

  defp policy do
    Enum.join(
      [
        "default-src 'none'",
        "img-src https: data:",
        "font-src https: data:",
        "style-src 'unsafe-inline'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors " <> RelayWeb.Endpoint.url(),
        "sandbox"
      ],
      "; "
    )
  end
end
