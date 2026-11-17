defmodule Relay.Agents.WakeHint do
  @moduledoc """
  The wake hint of a mailbox record (AG-21). When a record is appended, its `mailbox.record_appended` outbox event is the hint: the webhook engine delivers it to the endpoints that subscribe to it, and every transport configured here (`config :relay, Relay.Agents, wake_transports: [Module]`) derives its own jobs from it inside the outbox dispatch transaction, without a network call. A transport is where a protocol push, such as an A2A push notification, is attached.

  A hint names the record and its position and nothing else: no content and no sender. It is never the delivery. The record waits in the mailbox whether or not a hint is sent, arrives or is lost, and the reader takes it with a lease or reads it by the handle the hint carries.
  """

  @typedoc "What a hint says: the mailbox, the record's durable handle, its position in the mailbox stream, its kind and the trace context of the append."
  @type t :: %{
          mailbox_id: String.t(),
          record_id: String.t(),
          epoch: pos_integer(),
          seq: pos_integer(),
          kind: String.t(),
          traceparent: String.t() | nil
        }

  @doc "The jobs that carry a hint over this transport, queued by the outbox dispatcher in its transaction."
  @callback jobs(t()) :: [Ecto.Changeset.t()]

  @event "mailbox.record_appended"

  # AG-21
  @doc "The hint of a `mailbox.record_appended` outbox event, or `nil` for any other event."
  @spec from_event(map()) :: t() | nil
  def from_event(%{event_type: @event, payload: payload, epoch: epoch, seq: seq} = event) do
    case payload do
      %{"mailbox_id" => mailbox_id, "record_id" => record_id, "kind" => kind} ->
        %{
          mailbox_id: mailbox_id,
          record_id: record_id,
          epoch: epoch,
          seq: seq,
          kind: kind,
          traceparent: Map.get(event, :traceparent)
        }

      _other ->
        nil
    end
  end

  def from_event(_event), do: nil

  # AG-21
  @doc "The jobs every configured transport derives from an outbox event; none for an event that is no hint."
  @spec jobs(map()) :: [Ecto.Changeset.t()]
  def jobs(event) do
    case from_event(event) do
      nil -> []
      hint -> Enum.flat_map(transports(), & &1.jobs(hint))
    end
  end

  defp transports do
    :relay |> Application.get_env(Relay.Agents, []) |> Keyword.get(:wake_transports, [])
  end
end
