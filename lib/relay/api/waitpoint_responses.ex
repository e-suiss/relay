defmodule Relay.Api.WaitpointResponses do
  @moduledoc """
  The intake of responses to waitpoints from people (C-74, AG-25 … AG-28, AG-35): a subscriber's response in the session of its subscriber token (`relay_session`) and a response sent from a channel with a response token (`channel_claim`). The third path, the decision Access reports from its approval surface (`access_aas_ref`), arrives as an Access event and not through this API.

  Both operations check the value against the waitpoint's response schema with `Relay.Api.Waitpoints.check_response/2` before anything is recorded: a value that does not fit is not written and the caller gets the failing fields at once (INV-31, AG-11). The field is `response`, never "approval" (AG-26): Relay collects the response and passes it to the waiter, and the response is never an approval and gives no authority (E-49, AG-32).

  A waitpoint is resolved once (AG-28). The same response sent again is answered as the first was, so a repeated click changes nothing (AG-35); any other later response is rejected, and the rejection is recorded with its rule. A subscriber that is not a responder of a waitpoint is answered as if the waitpoint did not exist. Nothing these operations answer reaches the waiter, and what the waiter reads never carries a response token (AG-30).
  """

  alias Relay.Api.Views
  alias Relay.Api.Waitpoints
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  @session_channel "in_app"
  @link "link"
  @rule "waitpoint.response_"

  # AG-25
  # AG-26
  # AG-28
  # AG-11
  # INV-31
  @doc "Collects the response of the token subscriber to a waitpoint in its session; called outside any transaction."
  @spec respond(Scope.t(), Relay.Id.t(), Relay.Id.t(), map()) :: answer()
  def respond(%Scope{} = scope, subscriber_id, waitpoint_id, body) do
    "sha256:" <> hex = body["subject_digest"]

    attrs = %{
      responder_recipient_id: subscriber_id,
      actor_ref: Views.id("sub", subscriber_id),
      via: @session_channel,
      evidence_level: :relay_session,
      subject_digest: Base.decode16!(hex, case: :lower),
      value: body["response"]
    }

    check = &Waitpoints.check_response/2

    case Relay.Agents.collect_response(scope, waitpoint_id, attrs, check) do
      {:ok, {result, _response_id}} -> collected(scope, waitpoint_id, result)
      {:invalid, errors} -> {:error, invalid(errors)}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp collected(scope, waitpoint_id, result) when result in [:resolved, :duplicate] do
    case Relay.Agents.read_waitpoint(scope, waitpoint_id) do
      {:ok, %{response: %{} = response}} ->
        {:ok, {200, [], receipt(scope, waitpoint_id, response)}}

      _unreadable ->
        {:error, unavailable()}
    end
  end

  defp collected(_scope, _waitpoint_id, result)
       when result in [:not_found, :rejected_not_responder, :rejected_is_waiter],
       do: {:error, Waitpoints.not_found()}

  defp collected(_scope, _waitpoint_id, result)
       when result in [:rejected_closed, :rejected_expired],
       do: {:error, Relay.Error.new(:waitpoint_closed, "the waitpoint is closed")}

  defp collected(_scope, _waitpoint_id, :rejected_evidence_level) do
    message = "the waitpoint closes only with a decision given on the Access approval surface"
    {:error, Relay.Error.new(:waitpoint_response_refused, message)}
  end

  defp collected(_scope, _waitpoint_id, _digest_or_session_mismatch) do
    message = "the response is not bound to the subject of the waitpoint"
    {:error, Relay.Error.new(:waitpoint_response_refused, message)}
  end

  # AG-31
  # AG-35
  # AG-26
  # INV-31
  # INV-33
  @doc "Takes a response sent from a channel with a response token: `202` while it is being processed, `200` with what became of it once it was."
  @spec submit(map()) :: answer()
  def submit(%{"token" => token, "response" => _value} = body) do
    via = Map.get(body, "channel", @link)
    check = &Waitpoints.check_response/2

    case Relay.Agents.submit_channel_response(token, body["response"], via, check) do
      {:ok, %{state: :processing} = status} -> {:ok, {202, [], status_view(status)}}
      {:ok, status} -> {:ok, {200, [], status_view(status)}}
      {:invalid, errors} -> {:error, invalid(errors)}
      {:error, :token_invalid} -> {:error, token_invalid()}
      {:error, _reason} -> {:error, unavailable()}
    end
  end

  defp status_view(%{state: :processing, waitpoint_id: id}),
    do: receipt_base(id, :processing)

  defp status_view(%{state: :responded, waitpoint_id: id, response: response}),
    do: Map.merge(receipt_base(id, :responded), responded(response, %{}))

  defp status_view(%{state: :not_awaited, waitpoint_id: id, outcome: outcome}),
    do: Views.put_unless_nil(receipt_base(id, :not_awaited), "rule_id", rule(outcome))

  defp rule("rejected_" <> reason), do: @rule <> reason
  defp rule(_outcome), do: nil

  defp receipt(scope, waitpoint_id, response) do
    names =
      case Relay.Subscribers.external_ids(scope, [response.responder_recipient_id]) do
        {:ok, names} -> names
        {:error, _reason} -> %{}
      end

    Map.merge(receipt_base(waitpoint_id, :responded), responded(response, names))
  end

  defp receipt_base(waitpoint_id, status) do
    %{
      "object" => "waitpoint_response_receipt",
      "waitpoint_id" => Views.id("wp", waitpoint_id),
      "status" => Atom.to_string(status)
    }
  end

  defp responded(response, names) do
    prefix = Views.recipient_prefix(response.responder_kind)

    responder =
      Views.put_unless_nil(
        %{
          "recipient_id" => Views.id(prefix, response.responder_recipient_id),
          "kind" => response.responder_kind
        },
        "external_id",
        Map.get(names, response.responder_recipient_id)
      )

    %{
      "response_id" => Views.id("wpr", response.id),
      "responder" => responder,
      "evidence_level" => response.evidence_level,
      "responded_at" => response.responded_at,
      "response_digest" => "sha256:" <> Base.encode16(response.value_digest, case: :lower)
    }
  end

  defp invalid([%{} | _] = errors), do: broken(nested(errors))

  defp invalid(_reason),
    do: broken([%{pointer: "/response", code: "invalid_format", detail: "not a response"}])

  defp broken(errors),
    do: Relay.Error.new(:validation_failed, "the response breaks a field rule", %{errors: errors})

  defp nested(errors), do: for(e <- errors, do: %{e | pointer: "/response" <> e.pointer})

  defp token_invalid,
    do: Relay.Error.new(:response_token_invalid, "the response token is not valid")

  defp unavailable, do: Relay.Error.new(:service_unavailable, "try again", %{retry_after: 1})
end
