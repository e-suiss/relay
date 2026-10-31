defmodule RelayWeb do
  @moduledoc """
  The web edge: the HTTP API, the operator API and its job queue panel, realtime transports, the MCP endpoint and static serving of the console.
  """

  use Boundary,
    deps: [
      Relay,
      Relay.Platform,
      Relay.Tenancy.KillSwitch,
      Relay.Datasets,
      Relay.Api,
      Relay.Access,
      Relay.Operators
    ],
    exports: [
      Endpoint,
      Metrics,
      Telemetry,
      Router,
      Auth,
      Auth.Access,
      Auth.Principal,
      Auth.Subscriber,
      Api.Pipeline,
      Api.Response
    ]

  @doc false
  def static_paths, do: ~w(.well-known robots.txt)

  @doc false
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  @doc false
  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn
    end
  end

  @doc false
  def api_controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      # INV-2
      # API-39
      @doc false
      def action(conn, opts) do
        super(conn, opts)
      rescue
        exception -> RelayWeb.Api.Response.exception(conn, exception, __STACKTRACE__)
      end
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
