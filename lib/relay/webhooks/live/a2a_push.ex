defmodule Relay.Webhooks.Live.A2aPush do
  @moduledoc """
  The A2A push wake transport (AG-42, AG-21, E-51, L-28): a wake transport of `Relay.Agents.WakeHint`, configured as `config :relay, Relay.Agents, wake_transports: [Relay.Webhooks.Live.A2aPush]`. It implements the `jobs/1` callback of that behaviour without naming it, because a context exports nothing but its root module.

  For the hint of a record in the mailbox of an active agent with an A2A push endpoint, it hands the A2A notification of the record (`Relay.Agents.a2a_push_in/2`) to the delivery engine as one message for that endpoint (`Relay.Webhooks.push_event/2`), inside the outbox dispatch transaction and without a network call. The engine then delivers it like every other message: signed with the endpoint's keys, retried on its schedule, dead-lettered, replayable and behind the address rules. The record's identifier is the identifier of the push, so dispatching the same record again creates nothing. The transport queues its work through the engine and returns no job of its own.
  """

  # AG-42
  # AG-21
  @doc "Hands the A2A push notification of a hinted mailbox record to the delivery engine inside the caller's scoped transaction; always returns no jobs."
  @spec jobs(map()) :: [Ecto.Changeset.t()]
  def jobs(%{mailbox_id: mailbox_text, record_id: record_text} = hint) do
    with {:ok, mailbox_id} <- Relay.Id.parse(mailbox_text),
         {:ok, record_id} <- Relay.Id.parse(record_text),
         %{endpoint_id: endpoint_id} = push <- Relay.Agents.a2a_push_in(mailbox_id, record_id) do
      _message =
        Relay.Webhooks.push_event(endpoint_id, %{
          id: push.record_id,
          type: Relay.Webhooks.a2a_push_type(),
          data: push.data,
          subject: "mailbox:" <> Relay.Id.to_string(push.mailbox_id),
          epoch: push.epoch,
          seq: push.seq,
          occurred_at: push.occurred_at,
          traceparent: Map.get(hint, :traceparent)
        })

      []
    else
      _none -> []
    end
  end
end
