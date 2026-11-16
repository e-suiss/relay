defmodule Relay.Api.WebhookCatalog do
  @moduledoc """
  Relay's event catalog on the server API (WH-14, WH-53): the event types an endpoint of use `relay_events` can subscribe to, paged by name, each with the version and the schema of its data. The catalog is the `tenantWebhooks` channel of the event contract (`Relay.EventCatalog`); an event type that is not in it is never delivered. The contract carries no example of an event's data, so `example` is `null`.
  """

  alias Relay.Api.Page
  alias Relay.Api.Pagination
  alias Relay.EventCatalog
  alias Relay.Scope

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # WH-14
  # WH-53
  # API-56
  @doc "Lists the catalog's event types by name."
  @spec list(Scope.t(), Pagination.page(), String.t()) :: answer()
  def list(%Scope{} = scope, page, endpoint) do
    rows = slice(numbered(), page.cursor, page.limit)

    with {:ok, body} <- Page.envelope(rows, page, scope, endpoint, &view/1, &position/1),
         do: {:ok, {200, [], body}}
  end

  defp numbered do
    for {name, number} <- Enum.with_index(EventCatalog.names(), 1),
        do: %{name: name, number: number}
  end

  defp slice(rows, nil, limit), do: Enum.take(rows, limit + 1)

  defp slice(rows, %{direction: :after, sort_ts_us: number}, limit),
    do: rows |> Enum.drop_while(&(&1.number <= number)) |> Enum.take(limit + 1)

  defp slice(rows, %{direction: :before, sort_ts_us: number}, limit),
    do: rows |> Enum.take_while(&(&1.number < number)) |> Enum.take(-(limit + 1))

  defp position(%{name: name, number: number}) do
    <<id::binary-16, _rest::binary>> = :crypto.hash(:sha256, name)
    {DateTime.from_unix!(number, :microsecond), id}
  end

  # WH-14
  @doc "The API view of a catalog event type."
  @spec view(%{name: String.t(), number: pos_integer()}) :: map()
  def view(%{name: name}) do
    {:ok, entry} = EventCatalog.fetch(name)
    {:ok, schema} = EventCatalog.schema(name)

    %{
      "object" => "webhook_catalog_event",
      "name" => name,
      "summary" => entry.summary,
      "version" => entry.version,
      "dataschema" => Relay.Webhooks.event_dataschema(name, entry.version),
      "schema" => schema,
      "example" => nil
    }
  end
end
