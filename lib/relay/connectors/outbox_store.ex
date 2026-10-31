defmodule Relay.Connectors.OutboxStore do
  @moduledoc """
  The SQL of the outbox source (`Relay.Connectors.Outbox`), run on the connector's own connection to the producer's database. The table name is checked when the connector is configured and quoted here; every value is a parameter.
  """

  # T-41
  @doc "Quotes a checked `name` or `schema.name` table identifier."
  @spec quoted_table(String.t()) :: String.t()
  def quoted_table(table) when is_binary(table),
    do: table |> String.split(".") |> Enum.map_join(".", &~s("#{&1}"))

  # T-41
  # L-42
  # sobelow_skip ["SQL.Query"]
  @doc "Claims up to `limit` of the oldest rows that are not relayed and not claimed, for `lease_s` seconds, and returns their ids and payloads."
  @spec claim(DBConnection.conn(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, [{integer(), String.t()}]} | {:error, Exception.t()}
  def claim(conn, table, limit, lease_s) do
    sql = """
    UPDATE #{table} AS o
       SET relay_claimed_until = clock_timestamp() + $2::integer * interval '1 second'
     WHERE o.id IN (
           SELECT c.id FROM #{table} AS c
            WHERE c.relayed_at IS NULL
              AND (c.relay_claimed_until IS NULL OR c.relay_claimed_until < clock_timestamp())
            ORDER BY c.id
            LIMIT $1::integer
              FOR UPDATE SKIP LOCKED)
    RETURNING o.id, o.payload::text
    """

    case Postgrex.query(conn, sql, [limit, lease_s]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.sort(for [id, payload] <- rows, do: {id, payload})}
      {:error, error} -> {:error, error}
    end
  end

  # T-41
  # sobelow_skip ["SQL.Query"]
  @doc "Records the outcome of relayed rows that are not relayed yet."
  @spec finish(DBConnection.conn(), String.t(), [integer()], String.t()) ::
          {:ok, non_neg_integer()} | {:error, Exception.t()}
  def finish(conn, table, ids, outcome) do
    sql = """
    UPDATE #{table}
       SET relayed_at = clock_timestamp(), relay_outcome = $2::text
     WHERE id = ANY($1::bigint[]) AND relayed_at IS NULL
    """

    case Postgrex.query(conn, sql, [ids, outcome]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end
end
