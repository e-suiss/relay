defmodule Relay.Api.Page do
  @moduledoc """
  The list envelope of a page read with `limit + 1` rows (API-56): whether more rows follow, and signed cursors for the next and the previous page. Rows come newest first; the cursor position is a row's sort time and identifier.
  """

  alias Relay.Api.Cursor
  alias Relay.Api.Pagination

  @type view :: (map() -> map())
  @type position :: (map() -> {DateTime.t(), Relay.Id.t()})

  # API-56
  @doc "Builds the list envelope of `rows` read for `page` at `endpoint`; `view` describes a row and `position` gives its `{sort_time, id}`."
  @spec envelope([map()], Pagination.page(), Relay.Scope.t(), String.t(), view(), position()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def envelope(rows, page, scope, endpoint, view, position) do
    direction = page.cursor && page.cursor.direction
    more? = length(rows) > page.limit
    data = data(rows, more?, direction, page.limit)
    next_row = if more? or direction == :before, do: List.last(data)
    previous_row = if previous?(more?, direction), do: List.first(data)

    with {:ok, next} <- cursor(scope, endpoint, next_row, position, :after),
         {:ok, previous} <- cursor(scope, endpoint, previous_row, position, :before) do
      {:ok, Pagination.envelope(Enum.map(data, view), next != nil, next, previous)}
    end
  end

  defp data(rows, false, _direction, _limit), do: rows
  defp data(rows, true, :before, _limit), do: Enum.drop(rows, 1)
  defp data(rows, true, _direction, limit), do: Enum.take(rows, limit)

  defp previous?(true, :before), do: true
  defp previous?(_more?, direction), do: direction == :after

  defp cursor(_scope, _endpoint, nil, _position, _direction), do: {:ok, nil}

  defp cursor(scope, endpoint, row, position, direction) do
    {at, id} = position.(row)
    at_us = DateTime.to_unix(at, :microsecond)
    Cursor.encode(scope, nil, endpoint, %{sort_ts_us: at_us, id: id}, direction)
  end
end
