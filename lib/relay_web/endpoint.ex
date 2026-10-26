defmodule RelayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :relay

  alias Relay.Config.SecretFiles
  alias Relay.Redacted

  @secret_key_base_min_bytes 64

  # TN-68 (1)
  @doc "Child specification of the endpoint under the application supervisor. It names no options: the endpoint reads `secret_key_base` from `Relay.Config.SecretFiles` each time it starts (`start_supervised/0`), so the plain value is neither in the application environment nor in the supervisor's child specification."
  @spec supervised() :: Supervisor.child_spec()
  def supervised,
    do: %{id: __MODULE__, start: {__MODULE__, :start_supervised, []}, type: :supervisor}

  # TN-68 (1)
  @doc "Starts the endpoint with the options of `secret_options/0`."
  @spec start_supervised() :: Supervisor.on_start()
  def start_supervised do
    with {:ok, opts} <- secret_options(), do: start_link(opts)
  end

  # TN-68 (1)
  @doc "The start options carrying `secret_key_base` read from its secret file; without a configured file (development and test nodes) the endpoint keeps its configuration. A secret shorter than #{@secret_key_base_min_bytes} bytes is refused."
  @spec secret_options() :: {:ok, keyword()} | {:error, :secret_key_base_too_short}
  def secret_options do
    if SecretFiles.configured?(:secret_key_base) do
      case Redacted.expose(SecretFiles.fetch!(:secret_key_base)) do
        secret when byte_size(secret) >= @secret_key_base_min_bytes ->
          {:ok, [secret_key_base: secret]}

        _short ->
          {:error, :secret_key_base_too_short}
      end
    else
      {:ok, []}
    end
  end

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
