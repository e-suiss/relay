defmodule RelayWeb.Metrics do
  @moduledoc """
  The internal metrics listener: `GET /metrics` in the Prometheus text format on a port of its own, separate from the API endpoint, so metrics are never served by the public listener. Configured under `config :relay, RelayWeb.Metrics` with `:server`, `:ip` and `:port`; every node runs it, whatever its roles.
  """

  @behaviour Plug

  import Plug.Conn

  # OP-71 (9)
  # OP-32
  @doc "The listener's children: one Bandit server when `:server` is true."
  @spec children() :: [Supervisor.child_spec()]
  def children do
    config = Application.get_env(:relay, __MODULE__, [])

    if Keyword.get(config, :server, false) do
      [
        Supervisor.child_spec(
          {Bandit,
           plug: __MODULE__,
           scheme: :http,
           ip: Keyword.fetch!(config, :ip),
           port: Keyword.fetch!(config, :port),
           startup_log: false},
          id: __MODULE__
        )
      ]
    else
      []
    end
  end

  @impl Plug
  def init(opts), do: opts

  # OP-71 (9)
  # OP-69
  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["metrics"]} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
    |> send_resp(200, RelayWeb.Telemetry.prometheus())
  end

  def call(conn, _opts), do: send_resp(conn, 404, "")
end
