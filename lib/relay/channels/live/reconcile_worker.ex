defmodule Relay.Channels.Live.ReconcileWorker do
  @moduledoc """
  The job of one reconciliation round (DS-22, DS-48): a scope, a channel and a provider in `status` or `report` mode, and for `report` the UTC day; identifiers only (T-15). The same round is queued once per sweep period. See `Relay.Channels.Live.Reconciliation`.
  """

  use Relay.Worker,
    queue: :maintenance,
    max_attempts: 3,
    timeout: 900_000,
    unique: [period: 240, fields: [:worker, :args]]

  alias Relay.Channels.Live.Reconciliation
  alias Relay.Scope

  # T-15
  @doc "The job changeset of the round of a data set entry (`provider`, `channel`, `mode`) in `scope`; `day` is the UTC day a report round reads."
  @spec job(Scope.t(), map(), Date.t()) :: Ecto.Changeset.t()
  def job(%Scope{} = scope, %{"provider" => provider, "channel" => channel} = entry, day) do
    mode = entry["mode"]

    scope
    |> Scope.to_job_args()
    |> Map.merge(%{"provider" => provider, "channel" => channel, "mode" => mode})
    |> put_day(mode, day)
    |> new()
  end

  defp put_day(args, "report", day), do: Map.put(args, "day", Date.to_iso8601(day))
  defp put_day(args, _mode, _day), do: args

  # DS-22
  # DS-48
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider, "channel" => channel} = args}) do
    with {:ok, scope} <- Scope.from_job_args(args),
         {:ok, settings} <- Reconciliation.settings(),
         {:ok, _counts} <- run(scope, provider, channel, args, settings) do
      :ok
    end
  end

  defp run(scope, provider, channel, %{"mode" => "status"}, settings),
    do: Reconciliation.status_round(scope, provider, channel, settings)

  defp run(scope, provider, channel, %{"mode" => "report", "day" => text}, _settings) do
    case Date.from_iso8601(to_string(text)) do
      {:ok, day} -> Reconciliation.report_round(scope, provider, channel, day)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(_scope, _provider, _channel, _args, _settings), do: {:error, :invalid_args}
end
