defmodule Relay.Workflow.Route do
  @moduledoc """
  The route seam of a channel step (WF-13, WF-59 (4)). A channel step names one `channel` or a `route`: the key of a named route or an inline route tree. `plan/1` turns the step into what the runner opens: `{:channel, name}` for a plain channel, or for a route whose tree is one plain channel leaf (a bare channel name inside `single` or `all` lists of one node, at any depth), and `{:unavailable, rule_id}` for every other route, which the runner records as the step's outcome instead of skipping it silently. Route tree evaluation (strategies, fallback triggers, escalation, named routes) plugs in here.

  `leaves/1` and `depth/1` measure an inline tree for the publication gate (depth at most 4, at most 10 leaves); `channels/1` lists the channel names a tree can reach.
  """

  @unavailable "workflow_run.route_unavailable"

  @type plan :: {:channel, String.t()} | {:unavailable, String.t()}

  # WF-13
  # WF-59
  @doc "What the runner opens for a channel step."
  @spec plan(map()) :: plan()
  def plan(%{"channel" => channel}) when is_binary(channel), do: {:channel, channel}

  def plan(%{"route" => %{} = tree}) do
    case leaf(tree) do
      {:ok, channel} -> {:channel, channel}
      :none -> {:unavailable, @unavailable}
    end
  end

  def plan(_step), do: {:unavailable, @unavailable}

  defp leaf(channel) when is_binary(channel), do: {:ok, channel}
  defp leaf(%{"single" => [node]} = tree) when map_size(tree) == 1, do: leaf(node)
  defp leaf(%{"all" => [node]}), do: leaf(node)
  defp leaf(_node), do: :none

  # WF-59
  @doc "The number of channel leaves of an inline route tree."
  @spec leaves(term()) :: non_neg_integer()
  def leaves(node), do: node |> nodes() |> length()

  # WF-59
  @doc "The nesting depth of an inline route tree; a bare channel is depth 1."
  @spec depth(term()) :: non_neg_integer()
  def depth(node) when is_binary(node), do: 1
  def depth(%{"channel" => _channel}), do: 1
  def depth(%{"single" => list}) when is_list(list), do: 1 + max_depth(list)
  def depth(%{"all" => list}) when is_list(list), do: 1 + max_depth(list)
  def depth(%{"last_active" => _channels}), do: 1
  def depth(%{"user_preference" => _channels}), do: 1

  def depth(%{"escalate" => %{"ladder" => ladder}}) when is_list(ladder),
    do: 1 + max_depth(Enum.map(ladder, & &1["node"]))

  def depth(_node), do: 1

  defp max_depth(list), do: list |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end)

  # WF-18
  @doc "The channel names an inline route tree can reach."
  @spec channels(term()) :: [String.t()]
  def channels(node), do: node |> nodes() |> Enum.uniq()

  defp nodes(channel) when is_binary(channel), do: [channel]
  defp nodes(%{"channel" => channel}) when is_binary(channel), do: [channel]
  defp nodes(%{"single" => list}) when is_list(list), do: Enum.flat_map(list, &nodes/1)
  defp nodes(%{"all" => list}) when is_list(list), do: Enum.flat_map(list, &nodes/1)
  defp nodes(%{"last_active" => list}) when is_list(list), do: list
  defp nodes(%{"user_preference" => list}) when is_list(list), do: list

  defp nodes(%{"escalate" => %{"ladder" => ladder}}) when is_list(ladder),
    do: Enum.flat_map(ladder, &nodes(&1["node"]))

  defp nodes(_node), do: []
end
