defmodule Relay.Webhooks.Portal do
  @moduledoc """
  The delivery log as one consumer sees it (WH-46, WH-47). A message belongs to the consumer of its endpoint; a message of another consumer, or of an endpoint that has no consumer, does not exist for the portal. The function runs inside the caller's scoped transaction.
  """

  alias Relay.Webhooks.LogStore

  @type id :: Relay.Id.t()

  # WH-47
  @doc "Reads a message whose endpoint belongs to `consumer_id`, as `Relay.Webhooks.LogStore.message/1` reads it, or `nil`."
  @spec message(id(), id()) :: map() | nil
  def message(<<_::128>> = consumer_id, id) do
    with %{"endpoint_id" => endpoint_id} = message <- LogStore.message(id),
         %{"consumer_id" => ^consumer_id} <- LogStore.endpoint(endpoint_id) do
      message
    else
      _missing_or_foreign -> nil
    end
  end
end
