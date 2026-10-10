defmodule Relay.Platform do
  @moduledoc """
  Platform components shared by the contexts: Valkey, rate limiting, fairness, lanes and queue components. Other contexts use only the functions of this module.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Platform.Store

  # T-63
  @doc "Checks the dependencies a node needs to serve traffic."
  @spec readiness() :: :ok | {:error, Relay.Error.t()}
  def readiness do
    case Store.ping() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Relay.Error.new(:not_ready, "database unavailable", %{reason: reason})}
    end
  end
end
