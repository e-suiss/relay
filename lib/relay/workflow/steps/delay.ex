defmodule Relay.Workflow.Steps.Delay do
  @moduledoc """
  The delay step (WF-8, WF-37): waits a `duration` from the business time base, or `until` the RFC 3339 timestamp an RFC 6901 pointer names in the event data. A time already passed goes on at once. A missing or unreadable timestamp stops the run with `workflow_run.delay_until_missing`, and one more than P90D ahead with `workflow_run.delay_out_of_range`, so nothing is sent at a time the workflow did not mean.
  """

  @behaviour Relay.Workflow.Step

  @max Relay.Limits.seconds!(["workflow", "delay_max"])

  # WF-37
  # WF-41
  @impl Relay.Workflow.Step
  def run(%{"duration" => duration}, _context, now) do
    case Relay.Workflow.Duration.seconds(duration) do
      {:ok, seconds} ->
        wait(DateTime.add(now, seconds, :second))

      :error ->
        {:stop, "workflow_run.delay_out_of_range", skipped("workflow_run.delay_out_of_range")}
    end
  end

  def run(%{"until" => pointer}, context, now) do
    with {:ok, text} when is_binary(text) <-
           Relay.Workflow.Definition.get(context.data, segments(pointer)),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      cond do
        DateTime.compare(at, now) != :gt ->
          {:continue, %{"outcome" => "elapsed", "until" => DateTime.to_iso8601(at)}}

        DateTime.diff(at, now, :second) > @max ->
          {:stop, "workflow_run.delay_out_of_range", skipped("workflow_run.delay_out_of_range")}

        true ->
          wait(at)
      end
    else
      _missing ->
        {:stop, "workflow_run.delay_until_missing", skipped("workflow_run.delay_until_missing")}
    end
  end

  defp wait(at),
    do: {:wait_until, at, %{"outcome" => "waited", "until" => DateTime.to_iso8601(at)}}

  defp skipped(rule_id), do: %{"outcome" => "skipped", "rule_id" => rule_id}

  defp segments(pointer) do
    pointer
    |> String.split("/")
    |> tl()
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end
end
