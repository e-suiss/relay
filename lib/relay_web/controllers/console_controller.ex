defmodule RelayWeb.ConsoleController do
  @moduledoc """
  The console (X-47): the React application built from `web/` into `priv/static/console` of the release. Its hashed assets are served by `Plug.Static` under `/console/assets`; every other `/console` path answers the application's `index.html`, which routes in the browser. The page is never cached, is not indexed and runs under a content security policy that allows only same-origin scripts, styles and API calls. A node without a built console, and an asset that does not exist, answer `404`. The console calls the server API from this origin with the operator session.
  """

  use RelayWeb, :controller

  @directives [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "manifest-src 'self'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'"
  ]

  # X-47
  # TP-39
  @doc "The content security policy of the console page; with a configured preview host (`Relay.Api.PreviewSandbox.host/0`) it may frame only that host's HTTPS origin, where rendered e-mail HTML is shown in a sandboxed `iframe`."
  @spec policy() :: String.t()
  def policy do
    case Relay.Api.PreviewSandbox.host() do
      nil -> Enum.join(@directives, "; ")
      host -> Enum.join(@directives ++ ["frame-src https://" <> host], "; ")
    end
  end

  # X-47
  @doc "The directory the built console is served from: `config :relay, RelayWeb.Console, root: path`, by default `priv/static/console` of the application."
  @spec root() :: Path.t()
  def root do
    :relay
    |> Application.get_env(RelayWeb.Console, [])
    |> Keyword.get_lazy(:root, fn -> Application.app_dir(:relay, "priv/static/console") end)
  end

  # X-47
  # X-4
  @doc "Answers the console application for any `/console` path."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"path" => ["assets" | _rest]}), do: send_resp(conn, 404, "")

  # sobelow_skip ["XSS.SendResp"]
  def show(conn, _params) do
    case index() do
      {:ok, html} ->
        conn
        |> put_secure_browser_headers(%{
          "content-security-policy" => policy(),
          "cache-control" => "no-store",
          "referrer-policy" => "same-origin",
          "x-robots-tag" => "noindex"
        })
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      :error ->
        send_resp(conn, 404, "")
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp index do
    case File.read(Path.join(root(), "index.html")) do
      {:ok, html} -> {:ok, html}
      {:error, _reason} -> :error
    end
  end
end
