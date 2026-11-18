defmodule Relay.Platform.Maintenance.ArchiveStore do
  @moduledoc """
  Database side of the cold archive, on `Relay.Platform.ArchiveRepo` as `relay_archive`: the detached leaves waiting for archive, their columns, a key-ordered read of one leaf, the archive manifests and the restore of an archived leaf into a read-only `restore_…` schema. Every write goes through a `relay_private` function that only `relay_archive` may call; the hot copy of a leaf is removed only by `relay_private.archive_drop` after the manifest is verified and the leaf still holds the verified number of rows.
  """

  alias Ecto.Adapters.SQL
  alias Relay.Platform.ArchiveRepo

  @ident ~r/^[a-z_][a-z0-9_]{0,62}$/
  @restore_schema ~r/^restore_[a-z0-9_]{1,54}$/
  @fetch_rows 1_000
  @leaves "relay_private.archive_leaves()"
  @begin "relay_private.archive_begin($1, $2, $3, $4, $5, $6, $7)"

  @type leaf :: %{
          table_name: String.t(),
          leaf_name: String.t(),
          range_from: DateTime.t(),
          range_to: DateTime.t(),
          retain_days: non_neg_integer() | nil
        }

  @type column :: %{name: String.t(), type: String.t(), key_position: pos_integer() | nil}

  # OP-15
  # OP-84
  # DS-44
  @doc "Lists the detached leaves waiting for archive, oldest range first, with the longest retention period in days of their table's retention classes (`nil` when no retention data set is active)."
  @spec leaves() :: {:ok, [leaf()]} | {:error, Relay.Error.t()}
  def leaves do
    select(
      "SELECT table_name, leaf_name, range_from, range_to, retain_days FROM #{@leaves}",
      [],
      fn [table, leaf, from, to, days] ->
        %{table_name: table, leaf_name: leaf, range_from: from, range_to: to, retain_days: days}
      end
    )
  end

  # OP-84
  @doc "Lists the columns of a detached leaf in table order, with their type and their position in the primary key."
  @spec columns(String.t()) :: {:ok, [column()]} | {:error, Relay.Error.t()}
  def columns(leaf) do
    with :ok <- ident(leaf) do
      select(
        """
        SELECT a.attname::text, format_type(a.atttypid, a.atttypmod),
          (SELECT k.ord::integer FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
            WHERE k.attnum = a.attnum)
        FROM pg_catalog.pg_attribute a
        LEFT JOIN pg_catalog.pg_index i ON i.indrelid = a.attrelid AND i.indisprimary
        WHERE a.attrelid = format('relay.%I', $1::text)::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """,
        [leaf],
        fn [name, type, position] -> %{name: name, type: type, key_position: position} end
      )
    end
  end

  # OP-84
  # sobelow_skip ["SQL.Stream"]
  @doc "Runs `fun` with the rows of a detached leaf, every value in its PostgreSQL text form, in primary key order (all columns when there is none), inside one repeatable-read, read-only transaction; returns what `fun` returns."
  @spec with_rows(String.t(), [column()], (Enumerable.t() -> result)) ::
          {:ok, result} | {:error, Relay.Error.t()}
        when result: term()
  def with_rows(leaf, columns, fun) when is_function(fun, 1) do
    with :ok <- ident(leaf) do
      transaction(fn ->
        ArchiveRepo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
        Enum.each(text_settings(), &ArchiveRepo.query!(&1, []))

        ArchiveRepo
        |> SQL.stream(select_sql(leaf, columns), [], max_rows: @fetch_rows)
        |> Stream.flat_map(& &1.rows)
        |> fun.()
      end)
    end
  end

  defp text_settings,
    do: [
      "SET LOCAL TimeZone = 'UTC'",
      "SET LOCAL DateStyle = 'ISO, YMD'",
      "SET LOCAL IntervalStyle = 'postgres'",
      "SET LOCAL bytea_output = 'hex'",
      "SET LOCAL extra_float_digits = 1"
    ]

  defp select_sql(leaf, columns) do
    values = Enum.map_join(columns, ", ", &(quote_ident(&1.name) <> "::text"))

    keys =
      case columns |> Enum.filter(& &1.key_position) |> Enum.sort_by(& &1.key_position) do
        [] -> columns
        key -> key
      end

    order = Enum.map_join(keys, ", ", &quote_ident(&1.name))
    "SELECT #{values} FROM relay.#{leaf} ORDER BY #{order}"
  end

  @doc "Quotes a column name as a PostgreSQL identifier."
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name) when is_binary(name),
    do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # OP-84
  @doc "Starts the manifest of an archive attempt of a detached leaf under the fencing token; returns the migration version of the schema."
  @spec begin(map(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def begin(manifest, token) do
    params = [
      manifest.id,
      manifest.table_name,
      manifest.leaf_name,
      manifest.object_key,
      manifest.schema_key,
      manifest.retain_until,
      token
    ]

    case query("SELECT result, migration_version FROM #{@begin}", params) do
      {:ok, [["started", version]]} -> {:ok, version}
      {:ok, [[result, _]]} -> refused(result)
      {:error, _} = error -> error
    end
  end

  # OP-84
  @doc "Records that the archived copy of an attempt was read back from the store and matched its row count and digest."
  @spec verified(Relay.Id.t(), map(), pos_integer()) :: :ok | {:error, Relay.Error.t()}
  def verified(id, %{rows: rows, digest: digest, bytes: bytes}, token),
    do:
      expect(
        "SELECT relay_private.archive_verified($1, $2, $3, $4, $5)",
        [id, rows, digest, bytes, token],
        "verified"
      )

  # OP-84
  @doc "Records that an attempt failed with `code`; the leaf stays detached and the next attempt starts from scratch."
  @spec failed(Relay.Id.t(), atom()) :: :ok | {:error, Relay.Error.t()}
  def failed(id, code),
    do:
      expect(
        "SELECT relay_private.archive_failed($1, $2)",
        [id, Atom.to_string(code)],
        "failed"
      )

  # OP-15
  # INV-47
  @doc "Removes the hot copy of a verified archive attempt's leaf under the fencing token."
  @spec drop(Relay.Id.t(), pos_integer()) :: :ok | {:error, Relay.Error.t()}
  def drop(id, token),
    do: expect("SELECT relay_private.archive_drop($1, $2)", [id, token], "archived")

  # OP-84
  @doc "Reads one archive manifest."
  @spec manifest(Relay.Id.t()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def manifest(id) do
    with {:ok, rows} <-
           select(
             """
             SELECT id, table_name, leaf_name, range_from, range_to, object_key, schema_key,
               migration_version, status, row_count, digest, file_bytes, archived_at
             FROM relay.archive_manifests WHERE id = $1
             """,
             [id],
             &manifest_row/1
           ) do
      case rows do
        [manifest] -> {:ok, manifest}
        [] -> {:error, Relay.Error.new(:not_found, "archive manifest not found")}
      end
    end
  end

  # OP-84
  @doc "Lists the archived manifests of a table, newest range first."
  @spec archived(String.t()) :: {:ok, [map()]} | {:error, Relay.Error.t()}
  def archived(table) do
    select(
      """
      SELECT id, table_name, leaf_name, range_from, range_to, object_key, schema_key,
        migration_version, status, row_count, digest, file_bytes, archived_at
      FROM relay.archive_manifests WHERE table_name = $1 AND status = 'archived'
      ORDER BY range_from DESC
      """,
      [table],
      &manifest_row/1
    )
  end

  defp manifest_row([
         id,
         table,
         leaf,
         from,
         to,
         object_key,
         schema_key,
         version,
         status,
         rows,
         digest,
         bytes,
         archived_at
       ]) do
    %{
      id: id,
      table_name: table,
      leaf_name: leaf,
      range_from: from,
      range_to: to,
      object_key: object_key,
      schema_key: schema_key,
      migration_version: version,
      status: status,
      rows: rows,
      digest: digest,
      bytes: bytes,
      archived_at: archived_at
    }
  end

  # OP-84
  # OP-14 (6)
  @doc "Restores rows into a new read-only `schema`: creates the schema with a partitioned copy of `table`, a staging leaf filled with `COPY` from `fun`, which receives a collector to call with lists of rows, then checks, attaches and seals the leaf."
  @spec restore(String.t(), map(), [String.t()], (tuple() -> term())) ::
          {:ok, non_neg_integer()} | {:error, Relay.Error.t()}
  def restore(schema, %{table_name: table, leaf_name: leaf} = manifest, columns, fun) do
    bounds = [manifest.range_from, manifest.range_to]

    with :ok <- restore_schema(schema),
         :ok <- private(:restore_prepare, [schema, table], "prepared"),
         :ok <- private(:staging_create, [schema, table, leaf], "created"),
         {:ok, copied} <- copy(schema, leaf, columns, fun),
         :ok <- private(:staging_attach, [schema, table, leaf | bounds], "attached"),
         :ok <- private(:restore_seal, [schema, table, leaf], "sealed") do
      {:ok, copied}
    end
  end

  defp private(name, params, expected) do
    placeholders = Enum.map_join(1..length(params), ", ", &"$#{&1}")
    expect("SELECT relay_private.#{name}(#{placeholders})", params, expected)
  end

  # sobelow_skip ["SQL.Stream"]
  defp copy(schema, leaf, columns, fun) do
    names = Enum.map_join(columns, ", ", &quote_ident/1)
    sql = "COPY #{schema}.#{leaf} (#{names}) FROM STDIN"

    transaction(fn ->
      {acc, collector} = Collectable.into(SQL.stream(ArchiveRepo, sql, []))

      push = fn rows, state -> collector.(state, {:cont, Enum.map(rows, &copy_line/1)}) end

      case fun.({acc, push}) do
        {:ok, state, count} ->
          collector.(state, :done)
          count

        {:error, _} = error ->
          ArchiveRepo.rollback(error)
      end
    end)
  end

  @doc "One row as a line of the PostgreSQL `COPY` text format."
  @spec copy_line([binary() | nil]) :: iolist()
  def copy_line(row), do: [Enum.map_intersperse(row, "\t", &copy_value/1), "\n"]

  defp copy_value(nil), do: "\\N"

  defp copy_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\t", "\\t")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end

  defp restore_schema(schema) do
    if is_binary(schema) and Regex.match?(@restore_schema, schema),
      do: :ok,
      else: {:error, Relay.Error.new(:invalid_argument, "restore schema must match restore_…")}
  end

  defp transaction(fun) do
    case ArchiveRepo.transaction(fun, timeout: :infinity) do
      {:ok, {:error, _} = error} -> error
      {:ok, result} -> {:ok, result}
      {:error, {:error, %Relay.Error{}} = error} -> error
      {:error, _} -> {:error, Relay.Error.new(:database_error, "archive transaction failed")}
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> error({:error, error})
  end

  defp expect(sql, params, expected) do
    case query(sql, params) do
      {:ok, [[^expected]]} -> :ok
      {:ok, [[other]]} -> refused(other)
      {:error, _} = error -> error
    end
  end

  defp refused(result),
    do: {:error, Relay.Error.new(:archive_refused, "archive step refused", %{result: result})}

  defp select(sql, params, row) do
    with {:ok, rows} <- query(sql, params), do: {:ok, Enum.map(rows, row)}
  end

  defp query(sql, params) do
    case ArchiveRepo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      other -> error(other)
    end
  end

  defp error({:error, %Postgrex.Error{postgres: %{code: code} = postgres}}) do
    details = %{sqlstate: code, reason: Map.get(postgres, :message)}
    {:error, Relay.Error.new(code_of(code), "archive query failed", details)}
  end

  defp error({:error, %DBConnection.ConnectionError{}}),
    do: {:error, Relay.Error.new(:database_unreachable, "archive database unreachable")}

  defp error(_other), do: {:error, Relay.Error.new(:database_error, "archive query failed")}

  defp code_of(:lock_not_available), do: :lock_timeout
  defp code_of(:query_canceled), do: :statement_timeout
  defp code_of(:insufficient_privilege), do: :insufficient_privilege
  defp code_of(_code), do: :database_error

  defp ident(name) do
    if is_binary(name) and Regex.match?(@ident, name),
      do: :ok,
      else: {:error, Relay.Error.new(:invalid_argument, "not a plain table name")}
  end
end
