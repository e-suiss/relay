defmodule Relay.Operators.AccessDecisionHandler do
  @moduledoc """
  The waitpoints' handler of the Access `approval.decided` event (E-15, AG-27): the decision a person gave on the Access approval surface is collected as the response of the subscriber whose `external_id` is the event's pairwise `sub`, at evidence level `access_aas_ref` with the reference of the decision (`Relay.Agents.collect_response/3`). The approval is given at Access; Relay records the response and passes it to the waiter, who verifies the approval at Access (E-49). A waitpoint of the profile `guardian_approval` closes only this way (AG-62). The decision is checked against the waitpoint's response schema like any response (INV-31) and bound to the subject digest it was given for (AG-11). Registered in `config :relay, Relay.Access, decision_handler: ...`; the event consumer calls it once for each environment of the event's tenant and an error retries the event, so it is idempotent: a decision that already resolved the waitpoint is answered as the first time.
  """

  @behaviour Relay.Access.DecisionHandler

  @via "access"

  # E-15
  # AG-27
  # AG-62
  # INV-31
  @impl Relay.Access.DecisionHandler
  def handle_decision(%Relay.Scope{} = scope, decision) do
    case Relay.ExternalId.decode(decision.waitpoint_id, ["wp"]) do
      {:ok, waitpoint_id} -> located(scope, waitpoint_id, decision)
      {:error, _error} -> {:rejected, "waitpoint_invalid"}
    end
  end

  defp located(scope, waitpoint_id, decision) do
    case Relay.Subscribers.locate(scope, decision.subject) do
      {:ok, nil} -> :unknown
      {:ok, recipient_id} -> collected(scope, waitpoint_id, recipient_id, decision)
      {:error, %Relay.Error{code: :not_found}} -> :unknown
      {:error, reason} -> {:error, reason}
    end
  end

  defp collected(scope, waitpoint_id, recipient_id, decision) do
    attrs = %{
      responder_recipient_id: recipient_id,
      actor_ref: decision.subject,
      via: @via,
      evidence_level: :access_aas_ref,
      evidence_ref: decision.decision_ref,
      subject_digest: decision.subject_digest,
      value: decision.value
    }

    case Relay.Agents.collect_response(scope, waitpoint_id, attrs) do
      {:ok, {result, _response_id}} when result in [:resolved, :duplicate] -> :ok
      {:ok, {:not_found, _response_id}} -> :unknown
      {:ok, {refusal, _response_id}} -> {:rejected, Atom.to_string(refusal)}
      {:invalid, _reason} -> {:rejected, "decision_invalid"}
      {:error, reason} -> {:error, reason}
    end
  end
end
