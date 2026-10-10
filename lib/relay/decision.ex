defmodule Relay.Decision do
  @moduledoc """
  Result type of pure decision code: either send with a route, or skip with a reason and the rule that decided it. A skip is a result, never an error, and never counts towards error metrics.
  """

  @type reason :: atom()
  @type rule_id :: String.t()
  @type t(route) :: {:send, route} | {:skip, reason(), rule_id()}
  @type t :: t(term())

  # T-58
  # INV-12
  @doc "Builds a send decision."
  @spec send(route) :: {:send, route} when route: term()
  def send(route), do: {:send, route}

  @doc "Builds a skip decision; the rule id is the spec or tenant rule that decided it."
  @spec skip(reason(), rule_id()) :: {:skip, reason(), rule_id()}
  def skip(reason, rule_id) when is_atom(reason) and is_binary(rule_id) and rule_id != "" do
    {:skip, reason, rule_id}
  end

  @doc "Returns true for a skip decision."
  @spec skip?(t()) :: boolean()
  def skip?({:skip, _reason, _rule_id}), do: true
  def skip?({:send, _route}), do: false
end
