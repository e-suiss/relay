defmodule Relay.Access.Pairing.Job do
  @moduledoc """
  The job that runs one pairing run (E-101) on the `maintenance` queue: `%{"scope" => "due"}` (node start, and the hourly cron entry, whose empty arguments mean the same), `%{"scope" => "all"}` or `%{"scope" => "tenant", "tenant" => id}`. An equal job queued in the last five minutes is not queued again.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 900_000, unique: [period: 300]

  alias Relay.Access.Pairing

  # E-101
  @doc "The arguments of a run of `scope`."
  @spec args(Pairing.scope()) :: map()
  def args(:due), do: %{"scope" => "due"}
  def args(:all), do: %{"scope" => "all"}
  def args({:tenant, tenant}) when is_binary(tenant),
    do: %{"scope" => "tenant", "tenant" => tenant}

  # E-101
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    _report = Pairing.run(scope(args))
    :ok
  end

  defp scope(%{"scope" => "all"}), do: :all
  defp scope(%{"scope" => "tenant", "tenant" => tenant}) when is_binary(tenant),
    do: {:tenant, tenant}
  defp scope(_due), do: :due
end
