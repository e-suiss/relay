defmodule Relay.Workflow.Steps.WaitForEvent do
  @moduledoc """
  The event wait step (WF-12, AG-13, AG-14): opens, through the run's `wait` effect, an event waitpoint of the run's recipient for the step's `event_type` and its rendered `correlation_key`, with the step's `match` as the second-stage condition and a deadline of the step's `timeout` (at most P30D) from the business time base. A waitpoint is a row and a timer (C-8, WF-43), so the run parks without holding anything.

  An event buffered in the recipient's mailbox before the wait opened resolves a wait without a `match` at once and the run goes on with `matched`. Otherwise the run parks until the waitpoint closes: a matching event resumes it with `matched`, the deadline with `timed_out` and the step's `on_timeout` steps (`Relay.Workflow.Runner.resume_wait/3`). A correlation key that renders empty or outside the waitpoint's printable ASCII range, and a waitpoint the store refuses (a limit, an inactive recipient), count as an immediate timeout (WF-12's timeout branch is mandatory): the step records `timed_out` with `workflow_run.wait_refused` and the reason, its `on_timeout` steps run, and the run goes on.
  """

  @behaviour Relay.Workflow.Step

  alias Relay.Workflow.Duration
  alias Relay.Workflow.KeyTemplate

  @refused "workflow_run.wait_refused"

  # WF-12
  # AG-9
  @impl Relay.Workflow.Step
  def run(step, context, now) do
    key = KeyTemplate.render(step["correlation_key"], context)

    with true <- key?(key),
         {:ok, seconds} <- Duration.seconds(step["timeout"]) do
      at = DateTime.add(now, seconds, :second)
      wait(context.effects.wait.(%{step: step, correlation_key: key, expires_at: at}), at)
    else
      _invalid -> refused("correlation_key_invalid")
    end
  end

  defp wait({:ok, %{state: :matched, waitpoint_id: id}}, _at),
    do: {:continue, %{"outcome" => "matched", "matched" => true, "waitpoint_id" => text(id)}}

  defp wait({:ok, %{state: :open, waitpoint_id: id}}, at),
    do:
      {:park,
       %{
         "outcome" => "waiting",
         "waitpoint_id" => text(id),
         "expires_at" => DateTime.to_iso8601(at)
       }}

  defp wait({:ok, %{state: :refused, reason: reason}}, _at), do: refused(reason)
  defp wait({:error, reason}, _at), do: {:error, reason}

  defp refused(reason),
    do:
      {:branch, ["on_timeout"],
       %{"outcome" => "timed_out", "timed_out" => true, "rule_id" => @refused, "reason" => reason}}

  defp text(<<_::128>> = id), do: Relay.Id.to_string(id)

  # AG-14
  @doc "Whether a rendered correlation key fits a waitpoint: 1 to 256 printable ASCII characters."
  @spec key?(term()) :: boolean()
  def key?(key) when is_binary(key), do: key =~ ~r/\A[\x21-\x7e]{1,256}\z/
  def key?(_key), do: false
end
