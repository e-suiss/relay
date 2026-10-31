defmodule Relay.Platform.Capacity.Store do
  @moduledoc """
  Database access of the lane capacities: `relay_ops.lane_capacity` through the `:lane_capacity` escape hatch, by counts only.
  """

  alias Relay.Repo

  # T-35 (2)
  @doc "Reads the backlog and the completions within `window_s` seconds of each bulk lane."
  @spec lane_capacity(pos_integer()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def lane_capacity(window_s) do
    {:ok, Repo.call_unscoped!(:lane_capacity, "relay_ops.lane_capacity", [window_s])}
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error,
       Relay.Error.new(:database_error, "lane capacity query failed", %{
         reason: error.__struct__
       })}
  end
end
