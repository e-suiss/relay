defmodule Relay.Connectors.OutboxStore do
  @moduledoc """
  The SQL of the outbox source (`Relay.Connectors.Outbox`), run on the connector's own connection to the producer's database. The table name is checked when the connector is configured and quoted here; every value is a parameter.

  The table shape is a contract (T-95), `contracts/connectors/outbox.sql`, read at compile time: `check/2` compares the producer's table with its columns and types.
  """

  @contract Path.expand("../../../contracts/connectors/outbox.sql", __DIR__)
  @external_resource @contract

  @column ~r/^ +([a-z_]+) ([a-z ]+?)(?: PRIMARY KEY| NOT NULL)?,?$/m
  @columns @column |> Regex.scan(File.read!(@contract)) |> Enum.map(&List.to_tuple(tl(&1)))

  # T-95
  @doc "The columns of the outbox contract with their PostgreSQL types, in contract order."
  @spec columns() :: [{String.t(), String.t()}, ...]
  def columns, do: @columns

  # T-95
  @doc "Compares a quoted table with the outbox contract: every contract column must exist with its type; other columns are the producer's own. Returns the differences, or the error of the query."
  @spec check(DBConnection.conn(), String.t()) ::
          :ok | {:mismatch, [String.t(), ...]} | {:error, Exception.t()}
  def check(conn, table) do
    sql = """
    SELECT a.attname::text, format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
     WHERE a.attrelid = to_regclass($1::text) AND a.attnum > 0 AND NOT a.attisdropped
    """

    case Postgrex.query(conn, sql, [table]) do
      {:ok, %{rows: []}} -> {:mismatch, ["table #{table} does not exist"]}
      {:ok, %{rows: rows}} -> differences(Map.new(rows, fn [name, type] -> {name, type} end))
      {:error, error} -> {:error, error}
    end
  end

  defp differences(found) do
    case Enum.flat_map(@columns, fn {name, type} -> difference(name, type, found[name]) end) do
      [] -> :ok
      problems -> {:mismatch, problems}
    end
  end

  defp difference(name, _type, nil), do: ["column #{name} is missing"]
  defp difference(_name, type, type), do: []

  defp difference(name, type, found),
    do: ["column #{name} is #{found}, the contract has #{type}"]

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
