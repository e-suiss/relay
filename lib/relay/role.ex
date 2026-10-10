defmodule Relay.Role do
  @moduledoc """
  Runtime roles of a node. One release serves every role; configuration selects which roles a node runs, and a small installation runs all three on one node.
  """

  @roles [:api, :worker, :socket]

  @type t :: :api | :worker | :socket

  # T-3
  @doc "All known roles."
  @spec all() :: [t()]
  def all, do: @roles

  @doc "Roles configured for this node."
  @spec configured() :: [t()]
  def configured, do: Application.fetch_env!(:relay, :roles)

  @doc "Returns true if this node runs the given role."
  @spec enabled?(t()) :: boolean()
  def enabled?(role) when role in @roles, do: role in configured()

  @doc "Returns true if this node serves HTTP or realtime traffic."
  @spec serves_http?() :: boolean()
  def serves_http?, do: enabled?(:api) or enabled?(:socket)
end
