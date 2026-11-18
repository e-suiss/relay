defmodule Relay.TenantLifecycle.ClosureJob do
  @moduledoc """
  The export job of a tenant closure (OP-86). On the `maintenance` queue it writes the full export of one closure (`Relay.TenantLifecycle.export_closure/2`); every file is written again under the same name when the job is retried, so a retry after a failure or a timeout starts over and leaves no partial manifest.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 20, timeout: 3_600_000

  # OP-86
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- closure_id(args["closure_id"]) do
      case Relay.TenantLifecycle.export_closure(scope.tenant_id, id) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp closure_id(text) when is_binary(text) do
    case Ecto.UUID.dump(text) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_closure_id}
    end
  end

  defp closure_id(_text), do: {:error, :invalid_closure_id}
end
