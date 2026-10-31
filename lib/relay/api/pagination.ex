defmodule Relay.Api.Pagination do
  @moduledoc """
  Cursor pagination of list endpoints (API-56): `limit` from 1 to 100 (default 50), `starting_after` or `ending_before` with a signed cursor (`Relay.Api.Cursor`), no offsets and no page numbers, and the list envelope `{object: "list", data, has_more, next_cursor, previous_cursor}`. The limits are the contract's `x-relay-limits.pagination`.
  """

  alias Relay.Api.Cursor

  @limits Relay.Api.Contract.limits()["pagination"]
  @default @limits["default_limit"]
  @max @limits["max_limit"]

  @type page :: %{
          limit: pos_integer(),
          cursor: Cursor.decoded() | nil
        }

  # API-56
  @doc "Reads the pagination parameters of a list request; every invalid parameter is reported."
  @spec params(map(), Relay.Scope.t(), Relay.Id.t() | nil, String.t()) ::
          {:ok, page()} | {:error, Relay.Error.t()}
  def params(query, scope, subject, endpoint) when is_map(query) do
    limit = limit(Map.get(query, "limit"))

    cursor =
      case {Map.get(query, "starting_after"), Map.get(query, "ending_before")} do
        {nil, nil} -> {:ok, nil}
        {after_cursor, nil} -> decode(scope, subject, endpoint, after_cursor, "starting_after")
        {nil, before} -> decode(scope, subject, endpoint, before, "ending_before")
        {_after, _before} -> {:error, [error("/ending_before", "conflict", "use one cursor")]}
      end

    case {limit, cursor} do
      {{:ok, limit}, {:ok, cursor}} -> {:ok, %{limit: limit, cursor: cursor}}
      {_limit, {:error, %Relay.Error{} = error}} -> {:error, error}
      {limit, cursor} -> {:error, failed(errors(limit) ++ errors(cursor))}
    end
  end

  # API-56
  @doc "The list envelope of a page."
  @spec envelope([term()], boolean(), String.t() | nil, String.t() | nil) :: map()
  def envelope(data, has_more, next_cursor, previous_cursor \\ nil) when is_list(data) do
    %{
      "object" => "list",
      "data" => data,
      "has_more" => has_more,
      "next_cursor" => next_cursor,
      "previous_cursor" => previous_cursor
    }
  end

  defp limit(nil), do: {:ok, @default}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n < 1 -> {:error, [error("/limit", "too_short", "limit is at least 1")]}
      {n, ""} when n > @max -> {:error, [error("/limit", "too_long", "limit is at most #{@max}")]}
      {n, ""} -> {:ok, n}
      _ -> {:error, [error("/limit", "invalid_format", "limit is an integer")]}
    end
  end

  defp limit(_value), do: {:error, [error("/limit", "invalid_format", "limit is an integer")]}

  defp decode(scope, subject, endpoint, cursor, param) do
    case Cursor.decode(scope, subject, endpoint, cursor, param) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Relay.Error{code: :validation_failed} = error} -> {:error, error.details.errors}
      {:error, error} -> {:error, error}
    end
  end

  defp errors({:error, errors}) when is_list(errors), do: errors
  defp errors(_ok), do: []

  defp failed(errors),
    do: Relay.Error.new(:validation_failed, "invalid pagination parameters", %{errors: errors})

  defp error(pointer, code, detail), do: %{pointer: pointer, code: code, detail: detail}
end
