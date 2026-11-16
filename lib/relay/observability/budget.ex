defmodule Relay.Observability.Budget do
  @moduledoc """
  The performance budget per request type, read at compile time from `priv/observability/budgets.json`: a latency and a reduction budget for every type, and the objective, the share of requests that stay within both. A request belongs to the first type that names its API operation, then to the first that names the first segments of its path, then to the type of its method. The nightly load run reads the same file and opens an issue when a type exceeds its latency budget.
  """

  @path Path.expand("../../../priv/observability/budgets.json", __DIR__)
  @external_resource @path

  @table @path |> File.read!() |> Jason.decode!()
  @types Enum.map(@table["types"], & &1["type"])

  @type request :: %{
          required(:method) => String.t(),
          required(:path_info) => [String.t()],
          optional(:operation) => String.t() | nil
        }

  # T-68 (3)
  @doc "The whole table as the data file writes it."
  @spec table() :: map()
  def table, do: @table

  # T-68 (3)
  @doc "The request types of the table."
  @spec types() :: [String.t(), ...]
  def types, do: @types

  # T-68 (3)
  @doc "The share of requests of a type that must stay within its budget."
  @spec objective() :: float()
  def objective, do: @table["objective"]

  # T-68 (3)
  @doc "The request type of a request; `nil` when no type claims it."
  @spec classify(request()) :: String.t() | nil
  def classify(request) do
    operation = Map.get(request, :operation)
    path = Enum.join(request.path_info, "/")

    found =
      find("operations", &(&1 == operation)) ||
        find("paths", &prefix?(path, &1)) ||
        find("methods", &(&1 == request.method))

    found && found["type"]
  end

  # T-68 (3)
  @doc "The resources of a request that exceeded the budget of its type: `:latency`, `:reductions` or both."
  @spec breaches(String.t(), non_neg_integer(), non_neg_integer()) :: [:latency | :reductions]
  def breaches(type, duration_ms, reductions) do
    budget = Enum.find(@table["types"], &(&1["type"] == type))

    over = [
      latency: duration_ms > budget["latency_ms"],
      reductions: reductions > budget["reductions"]
    ]

    for {resource, true} <- over, do: resource
  end

  defp find(key, matches),
    do: Enum.find(@table["types"], &Enum.any?(Map.get(&1, key, []), matches))

  defp prefix?(path, prefix), do: path == prefix or String.starts_with?(path, prefix <> "/")
end
