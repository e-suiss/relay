defmodule Relay.Workflow.Route do
  @moduledoc """
  The route seam of a channel step (WF-13, WF-14). The workflow run resolves the tree a step sends through once, when the notification is created, and copies it into the notification's plan (WF-59 (4), WF-7); a later change to a named route applies to new decisions only. It then asks `next/3` for the next actions every time a result of the route changes or its `wake_at` comes; see `Relay.Workflow.RouteTree` for the tree and its semantics.

  Resolution order (WF-14): the step's own `route` (a route key or an inline tree), else the step's `channel`, else the default route of the workflow's category. A route key that is unknown or archived resolves to `{:skip, "route.not_found"}`: the notification is recorded with that rule and nothing is sent.
  """

  alias Relay.Workflow.RouteStore
  alias Relay.Workflow.RouteTree

  @type source :: :step | :channel | :category
  @type tree :: String.t() | map()

  # WF-14
  # WF-59 (4)
  @doc "Resolves the tree of a channel step inside the caller's scoped transaction: the step's `route` (key or inline tree), else its `channel`, else the default route of `category_key`. Returns the tree with where it came from, or `{:skip, \"route.not_found\"}`."
  @spec resolve(map(), String.t() | nil) :: {:ok, tree(), source()} | {:skip, String.t()}
  def resolve(step, category_key) do
    case step do
      %{"route" => %{} = tree} -> {:ok, tree, :step}
      %{"route" => key} when is_binary(key) -> named(key, :step)
      %{"channel" => channel} when is_binary(channel) -> {:ok, channel, :channel}
      _other -> category(category_key)
    end
  end

  defp category(nil), do: {:skip, "route.not_found"}

  defp category(category_key) do
    case RouteStore.category_default(category_key) do
      nil -> {:skip, "route.not_found"}
      key -> named(key, :category)
    end
  end

  defp named(key, source) do
    case RouteStore.get(key) do
      %{"state" => "active", "tree" => tree} -> {:ok, tree, source}
      _missing -> {:skip, "route.not_found"}
    end
  end

  # WF-13
  # WF-15
  # WF-21
  @doc "The next actions of a resolved tree; see `Relay.Workflow.RouteTree.next/3`."
  @spec next(tree(), RouteTree.facts(), RouteTree.state()) ::
          {:ok, RouteTree.plan()} | {:error, [RouteTree.field_error()]}
  defdelegate next(tree, facts, state), to: RouteTree

  # WF-18
  # WF-59 (4)
  @doc "Validates a tree; see `Relay.Workflow.RouteTree.validate/2`."
  @spec validate(term(), keyword()) :: :ok | {:error, [RouteTree.field_error()]}
  defdelegate validate(tree, opts \\ []), to: RouteTree

  # WF-16
  @doc "The channels a tree names, for the facts the caller gathers; see `Relay.Workflow.RouteTree.channels/1`."
  @spec channels(term()) :: [String.t()]
  defdelegate channels(tree), to: RouteTree
end
