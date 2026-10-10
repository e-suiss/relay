defmodule RelayWeb do
  @moduledoc """
  The web edge: the HTTP API, realtime transports, the MCP endpoint and static serving of the console.
  """

  use Boundary, deps: [Relay, Relay.Platform], exports: [Endpoint, Telemetry]

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

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
