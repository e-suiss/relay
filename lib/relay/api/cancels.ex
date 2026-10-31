defmodule Relay.Api.Cancels do
  @moduledoc """
  Cancellation (API-57 … API-59, INV-60): by event, by notification and by cancellation key with optional recipient and channel filters. No key needs registering first, and no match is not an error. A cancellation is processed from the same ordered key as the trigger and leaves a tombstone (`cnl_`), so a run that has not started yet ends cancelled. Only deliveries not yet handed to a provider stop; a sent message is counted `already_sent`. Always `200` with counts, never `204`. One call handles at most 1000 notifications and says `has_more`.
  """

  alias Relay.Api.Views

  @limit 1000

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # API-57
  # API-59
  @doc "Cancels an event inside the request's transaction."
  @spec event(Relay.Id.t(), String.t() | nil, Relay.Actor.t()) :: answer()
  def event(event_id, reason, actor) do
    id = Relay.Id.generate()

    case Relay.Ingest.cancel_event(id, event_id, reason, @limit, actor) do
      %{"result" => :not_found} -> {:error, Relay.Error.new(:event_not_found, "no such event")}
      row -> {:ok, {200, [], Views.cancellation(id, row)}}
    end
  end

  # API-57
  @doc "Cancels a notification inside the request's transaction."
  @spec notification(Relay.Id.t(), String.t() | nil, Relay.Actor.t()) :: answer()
  def notification(notification_id, reason, actor) do
    id = Relay.Id.generate()

    case Relay.Ingest.cancel_notification(id, notification_id, reason, actor) do
      %{"result" => :not_found} ->
        {:error, Relay.Error.new(:notification_not_found, "no such notification")}

      row ->
        {:ok, {200, [], Views.cancellation(id, row)}}
    end
  end

  # API-57
  # API-58
  # INV-60
  @doc "Cancels by cancellation key inside the request's transaction; `indexes` are the blind indexes of the recipient filter, computed before."
  @spec by_key(map(), [binary()] | nil, Relay.Actor.t()) :: answer()
  def by_key(body, indexes, actor) do
    id = Relay.Id.generate()
    recipients = indexes && Relay.Subscribers.resolve_indexes(indexes)
    unknown = if indexes, do: length(indexes) - length(recipients), else: 0

    row =
      if recipients == [] do
        %{"cancelled" => 0, "already_sent" => 0, "not_found" => 0, "has_more" => false}
      else
        Relay.Ingest.cancel_by_key(
          %{
            id: id,
            key: body["cancellation_key"],
            recipient_ids: recipients,
            channels: body["channels"],
            reason: body["reason"],
            limit: @limit
          },
          actor
        )
      end

    {:ok, {200, [], Views.cancellation(id, Map.update!(row, "not_found", &(&1 + unknown)))}}
  end
end
