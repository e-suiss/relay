defmodule RelayTest.OutboxEvents do
  @moduledoc """
  Reads the outbox events of one type in a scope as the thin data a tenant's endpoint receives, and checks each against the event's schema in the catalog: every required field is present and no field is outside the schema.
  """

  import ExUnit.Assertions

  alias Relay.Repo

  @sql "SELECT payload FROM relay.outbox_events WHERE event_type = $1 ORDER BY created_at, id"

  @doc "The data of the outbox events of `type` in `scope`, oldest first."
  @spec data(Relay.Scope.t(), String.t()) :: [map()]
  def data(scope, type) do
    assert {:ok, %{data: schema}} = Relay.EventCatalog.fetch(type)
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(@sql, [type]).rows end)

    for [payload] <- rows do
      data = Relay.Platform.Envelope.data(payload)
      assert schema["required"] -- Map.keys(data) == [], type
      assert Map.keys(data) -- Map.keys(schema["properties"]) == [], type
      data
    end
  end
end
