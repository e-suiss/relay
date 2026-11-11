defmodule Relay.Observability.Store do
  @moduledoc """
  Database access of the observability rollup: `relay_ops.observability_rollup` through the `:observability_rollup` escape hatch, by counts only.
  """

  alias Relay.Repo

  # OP-33
  # OP-36
  # TN-62
  @doc "Counts the ledger events received in `(from, to]` by kind, label, message class, channel and provider, and the queued jobs of each queue with the largest tenant's share."
  @spec rollup(DateTime.t(), DateTime.t(), %{String.t() => pos_integer()}) ::
          {:ok, [map()]} | {:error, Relay.Error.t()}
  def rollup(from, to, handoff_ms) do
    params = [from, to, handoff_ms]
    {:ok, Repo.call_unscoped!(:observability_rollup, "relay_ops.observability_rollup", params)}
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error,
       Relay.Error.new(:database_error, "observability rollup failed", %{
         reason: error.__struct__
       })}
  end
end
