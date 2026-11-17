defmodule Relay.Agents.Response do
  @moduledoc """
  Response collection (C-74, AG-25 … AG-28, AG-35, E-49). Relay collects the response to a question or a review and passes it to the owner: the value, the responder, the channel, the evidence level, the time and the subject digest. It carries the response, never its validity: a response is not an approval and produces no authority (INV-28, INV-29, AG-2).

  A response arrives on one of three paths, and the path is its evidence level (AG-26):

  * `relay_session`: a subscriber answers in a session authenticated with the subscriber token (`collect/4`).
  * `channel_claim`: a button or a reply of a channel, which carries a response token (`Relay.Agents.ResponseToken`); the channel is acknowledged at once and the response is processed by a job (`submit/4`, `process/2`), so the item goes from processing to responded (AG-35).
  * `access_aas_ref`: the decision given on the Access approval surface, reported by Access with its reference (`collect/4`, AG-27). A waitpoint of the profile `guardian_approval` closes only this way; any other response to it is rejected and the rejection recorded (AG-62, AG-32).

  The value is checked against the waitpoint's response schema before it is sealed: an invalid value is not written and the caller is told at once (INV-31, AG-11). The first valid response resolves the waitpoint; the same response sent again is answered as the first was, and any other later response is rejected and the rejection recorded with its rule (AG-28).
  """

  alias Relay.Agents.ResponseStore
  alias Relay.Agents.ResponseToken
  alias Relay.Agents.ResponseValue
  alias Relay.Agents.WaitpointStore

  @type check :: (map() | nil, term() -> :ok | {:error, term()})
  @type attrs :: %{
          required(:responder_recipient_id) => Relay.Id.t(),
          required(:actor_ref) => String.t(),
          required(:via) => String.t(),
          required(:evidence_level) => :relay_session | :access_aas_ref | :channel_claim,
          required(:subject_digest) => <<_::256>>,
          required(:value) => term(),
          optional(:evidence_ref) => String.t() | nil
        }
  @type status :: %{
          state: :processing | :responded | :not_awaited,
          waitpoint_id: Relay.Id.t(),
          outcome: String.t() | nil,
          response: map() | nil
        }

  # AG-11
  # AG-25
  # AG-26
  # AG-27
  # AG-28
  # INV-31
  @doc """
  Collects a response given by an identified responder; called outside any transaction. `check` decides whether the value fits the waitpoint's response schema, by default `Relay.Agents.ResponseValue.check/2`; a value that does not fit is `{:invalid, reason}` and nothing is written.

  The result is that of `relay_fn.waitpoint_respond`: `:resolved` or `:duplicate` with the response, `:not_found`, or a `:rejected_*` refusal, which is recorded.
  """
  @spec collect(Relay.Scope.t(), Relay.Id.t(), attrs(), check()) ::
          {:ok, {atom(), Relay.Id.t() | nil}} | {:invalid, term()} | {:error, term()}
  def collect(%Relay.Scope{} = scope, waitpoint_id, attrs, check \\ &ResponseValue.check/2) do
    with {:ok, waitpoint} <- asked(scope, waitpoint_id),
         :ok <- checked(check, waitpoint, attrs.value),
         {:ok, sealed} <- sealed(scope, waitpoint, attrs) do
      respond(scope, waitpoint_id, attrs, sealed)
    else
      :not_found -> {:ok, {:not_found, nil}}
      other -> other
    end
  end

  defp asked(scope, waitpoint_id) do
    read =
      WaitpointStore.in_scope(scope, fn _status ->
        case WaitpointStore.get(waitpoint_id) do
          %{kind: kind} = waitpoint when kind in ["question", "review"] ->
            responders = WaitpointStore.responders([waitpoint_id])
            Map.put(waitpoint, :responders, Map.get(responders, waitpoint_id, []))

          _missing_or_event ->
            nil
        end
      end)

    case read do
      {:ok, nil} -> :not_found
      {:ok, waitpoint} -> {:ok, waitpoint}
      {:error, %Relay.Error{code: :not_found}} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp checked(check, waitpoint, value) do
    case check.(waitpoint.response_schema, value) do
      :ok -> :ok
      {:error, reason} -> {:invalid, reason}
    end
  end

  defp sealed(scope, waitpoint, %{responder_recipient_id: recipient_id, value: value}) do
    if Enum.any?(waitpoint.responders, fn {id, _kind} -> id == recipient_id end) do
      ResponseValue.seal(scope, recipient_id, value)
    else
      {:ok, %{value_ct: nil, value_key_id: nil, value_digest: ResponseValue.digest(value)}}
    end
  end

  defp respond(scope, waitpoint_id, attrs, sealed) do
    response = %{
      id: Relay.Id.generate(),
      responder_recipient_id: attrs.responder_recipient_id,
      responder_actor_ref: attrs.actor_ref,
      session_actor_ref: attrs.actor_ref,
      via: attrs.via,
      evidence_level: attrs.evidence_level,
      evidence_ref: Map.get(attrs, :evidence_ref),
      subject_digest: attrs.subject_digest,
      value_ct: sealed.value_ct,
      value_key_id: sealed.value_key_id,
      value_digest: sealed.value_digest
    }

    WaitpointStore.in_scope(scope, fn _status ->
      WaitpointStore.respond(waitpoint_id, response)
    end)
  end

  # AG-31
  # AG-35
  # INV-31
  # INV-33
  @doc """
  Takes a channel response: the bearer of a response token sends a value on the channel `via`. The token is verified, the value is checked against the waitpoint's response schema (`{:invalid, reason}`, the token stays unused), sealed for the token's responder and consumed with the token; the response itself is processed by a job. The answer is the status of the response: `:processing` at first, and `:responded` or `:not_awaited` once the job ran. Sending the same value with the same token again changes nothing and answers the current status; a forged, rotated, expired or otherwise used token is `{:error, :token_invalid}`.
  """
  @spec submit(term(), term(), String.t(), check()) ::
          {:ok, status()} | {:invalid, term()} | {:error, term()}
  def submit(token, value, via, check \\ &ResponseValue.check/2) do
    with {:ok, held} <- held(ResponseToken.peek(token)),
         {:ok, waitpoint} <- asked(held.scope, held.waitpoint_id),
         :ok <- checked(check, waitpoint, value) do
      used(held, token, value, via)
    else
      :not_found -> {:error, :token_invalid}
      other -> other
    end
  end

  defp held({:ok, token}), do: {:ok, token}
  defp held({:error, :invalid}), do: {:error, :token_invalid}
  defp held({:error, reason}), do: {:error, reason}

  defp used(%{state: "issued"} = held, token, value, via) do
    with {:ok, sealed} <- ResponseValue.seal(held.scope, held.recipient_id, value) do
      case ResponseToken.verify_and_consume(token, Map.put(sealed, :via, via)) do
        {:ok, _used, _claims} -> status(held.scope, held.id)
        {:error, refusal} when is_atom(refusal) -> {:error, :token_invalid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp used(%{state: state} = held, _token, value, _via)
       when state in ["processing", "settled"] do
    if held.value_digest == ResponseValue.digest(value),
      do: status(held.scope, held.id),
      else: {:error, :token_invalid}
  end

  defp used(_rotated, _token, _value, _via), do: {:error, :token_invalid}

  # AG-35
  @doc "The status of the response a token was used with: `:processing` until its job ran, then `:responded` with the response that resolved the waitpoint (who and when), or `:not_awaited` with the outcome that refused it."
  @spec status(Relay.Scope.t(), Relay.Id.t()) :: {:ok, status()} | {:error, term()}
  def status(%Relay.Scope{} = scope, token_id) do
    read =
      ResponseStore.in_scope(scope, fn _status ->
        case ResponseStore.token(token_id) do
          nil -> nil
          token -> {token, settled_response(token)}
        end
      end)

    case read do
      {:ok, {token, response}} -> {:ok, view(token, response)}
      {:ok, nil} -> {:error, :token_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settled_response(%{state: "settled", outcome: outcome, waitpoint_id: waitpoint_id})
       when outcome in ["resolved", "duplicate"],
       do: Map.get(WaitpointStore.responses([waitpoint_id]), waitpoint_id)

  defp settled_response(_token), do: nil

  defp view(%{state: "settled"} = token, %{} = response) do
    %{
      state: :responded,
      waitpoint_id: token.waitpoint_id,
      outcome: token.outcome,
      response: Map.delete(response, :value_ct)
    }
  end

  defp view(%{state: "settled"} = token, nil) do
    %{
      state: :not_awaited,
      waitpoint_id: token.waitpoint_id,
      outcome: token.outcome,
      response: nil
    }
  end

  defp view(token, _response),
    do: %{state: :processing, waitpoint_id: token.waitpoint_id, outcome: nil, response: nil}

  # AG-35
  # AG-28
  @doc "Processes a consumed token in one transaction: offers its response to the waitpoint as a `channel_claim` and settles the token with the outcome. A token that is settled, or was never consumed, is left as it is."
  @spec process(Relay.Scope.t(), Relay.Id.t()) ::
          {:ok, {atom(), String.t() | nil}} | {:error, term()}
  def process(%Relay.Scope{} = scope, token_id) do
    ResponseStore.in_scope(scope, fn _status ->
      ResponseStore.token_process(token_id, Relay.Id.generate())
    end)
  end
end
