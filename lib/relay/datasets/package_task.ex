defmodule Relay.Datasets.PackageTask do
  @moduledoc """
  The `dataset_packages` singleton task: publishes the data set versions bundled with the running release (`Relay.Datasets.load_package/2`), so an upgrade brings its new versions without a deploy step. A run that finds nothing new changes nothing; it runs at start and daily after that. Telemetry: `[:relay, :datasets, :package_loaded]` per data set with the count of new versions.
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  @every_ms 24 * 60 * 60_000
  @actor %Relay.Actor{kind: :system, ref: "relay:dataset_packages", on_behalf_of_ref: "relay"}

  # OP-65 (5)
  @impl Relay.Platform.Leadership
  @doc "Publishes the bundled versions once and schedules the next run a day later."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(_context) do
    case Relay.Datasets.load_package(@actor) do
      {:ok, report} ->
        for {name, %{published: published, activation: activation}} <- report do
          :telemetry.execute(
            [:relay, :datasets, :package_loaded],
            %{published: length(published)},
            %{dataset: name, activation: activation}
          )
        end

        {:ok,
         %{"loaded_at" => DateTime.to_iso8601(Relay.Clock.utc_now()), "report" => json(report)},
         @every_ms}

      {:error, error} ->
        Logger.error("bundled data sets not loaded", code: error.code)
        {:error, error}
    end
  end

  defp json(report) do
    Map.new(report, fn {name, %{published: published, activation: activation}} ->
      {name, %{"published" => published, "activation" => Atom.to_string(activation)}}
    end)
  end
end
