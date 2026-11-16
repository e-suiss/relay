defmodule Relay.Delivery.ExportJob do
  @moduledoc """
  The raw data export job (DS-37). On the `maintenance` queue it writes the CSV of one pending export of its scope (`Relay.Delivery.Exports.Store.run/2`); an export that the report pool could not read by the last attempt fails as `unavailable`, so it never stays pending.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 3, timeout: 1_800_000

  # DS-37
  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- found(Ecto.UUID.dump(args["export_id"] || "")) do
      case Relay.Delivery.run_export(scope, id) do
        {:ok, _result} -> :ok
        {:error, reason} when attempt >= max -> give_up(scope, id, reason)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp found({:ok, id}), do: {:ok, id}
  defp found(:error), do: {:error, :invalid_export_id}

  defp give_up(scope, id, reason) do
    _ = Relay.Delivery.fail_export(scope, id)
    {:cancel, reason}
  end
end
