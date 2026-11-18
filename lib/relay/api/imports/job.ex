defmodule Relay.Api.Imports.Job do
  @moduledoc """
  The job of an import (OP-96). On the `maintenance` queue it runs one pending import of its scope (`Relay.Api.Imports.run/2`); it carries only identifiers (T-15). Every write it makes is idempotent, so a retry after an unavailable store writes nothing twice; an import whose stores were still unavailable at the last attempt fails as `unavailable`, so it never stays pending.
  """

  use Relay.Worker, queue: :maintenance, max_attempts: 5, timeout: 3_600_000

  alias Relay.Api.Imports

  # OP-96
  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max}) do
    with {:ok, scope} <- Relay.Scope.from_job_args(args),
         {:ok, id} <- Relay.Id.parse(args["import_id"] || "") do
      case Imports.run(scope, id) do
        {:ok, _result} -> :ok
        {:error, reason} when attempt >= max -> give_up(scope, id, reason)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:cancel, reason}
    end
  end

  defp give_up(scope, id, reason) do
    _ = Imports.fail(scope, id)
    {:cancel, reason}
  end
end
