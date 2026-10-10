defmodule RelayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :relay

  plug Plug.Static, at: "/", from: :relay, gzip: false, only: RelayWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId, http_header: "request-id"
  plug RelayWeb.Plugs.Correlation
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug RelayWeb.Router
end
