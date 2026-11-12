defmodule Relay.Workflow.Steps.Digest do
  @moduledoc """
  The digest step (WF-26, WF-27): adds the run's event to the digest window of its rendered `digest_key` through the run's digest effect (`Relay.Workflow.Digest.add/2`) and follows the window's answer. The first digested item (`anchor`) parks the run until the window fires and the digest sink resumes it with the digest render data, or with the singular path for a window of one activity; a `folded` item ends the run, its activity being part of the anchor's digest; the first event of a `leading: immediate` window (`sent_alone`) goes on at once.
  """

  @behaviour Relay.Workflow.Step

  # WF-26
  # WF-27
  @impl Relay.Workflow.Step
  def run(step, context, _now) do
    case context.effects.digest.(step) do
      {:ok, %{role: :anchor, window_id: id}} ->
        {:park, %{"outcome" => "anchor", "window_id" => Relay.Id.to_string(id)}}

      {:ok, %{role: :folded, window_id: id}} ->
        {:end, %{"outcome" => "folded", "window_id" => Relay.Id.to_string(id)}}

      {:ok, %{role: :sent_alone, window_id: id}} ->
        {:continue, %{"outcome" => "sent_alone", "window_id" => Relay.Id.to_string(id)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
