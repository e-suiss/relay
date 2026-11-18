defmodule Relay.Platform.Maintenance.Archive do
  @moduledoc """
  Moves one detached leaf to the cold archive. The steps run in order and stop at the first failure: start a manifest under the fencing token; read the leaf in key order and write it as Parquet through `Relay.Parquet`; write the Parquet file and a schema file (columns, types, key, migration version, row count and digest) to the in-region object-locked archive store, locked until the longest retention period of the table's retention classes or the bucket's default period, whichever ends later; read the Parquet object back from the store and check its row count, digest and columns against what was written; record the manifest as verified; and only then remove the hot copy through `relay_private.archive_drop`, which itself checks that the leaf still holds the verified number of rows. A failed attempt is recorded on its manifest and leaves the leaf detached; the next attempt starts from scratch with a new manifest and new object keys.
  """

  alias Relay.ObjectStore.S3
  alias Relay.Platform.Maintenance.ArchiveStore

  @schema_format "relay-archive/1"
  @json "application/json"

  # OP-15
  # OP-84
  # INV-47
  # DS-44
  @doc "Archives `leaf` (an entry of `ArchiveStore.leaves/0`) under the fencing token with the archive store options `store`; returns the verified summary."
  @spec run(ArchiveStore.leaf(), pos_integer(), keyword(), keyword()) ::
          {:ok, map()} | {:error, Relay.Error.t()}
  def run(leaf, token, store, opts \\ []) do
    with :ok <- valid_store(store),
         {:ok, days} <- retain_days(leaf),
         {:ok, {_mode, period}} <- S3.lock_rule(store) do
      id = Relay.Id.generate()
      until = S3.retain_until(period, Relay.Clock.utc_now(), days)
      manifest = manifest(id, leaf, until)

      with {:ok, version} <- ArchiveStore.begin(manifest, token) do
        manifest
        |> Map.put(:migration_version, version)
        |> in_scratch(token, store, opts)
        |> record_failure(id)
      end
    end
  end

  defp in_scratch(manifest, token, store, opts) do
    with {:ok, dir} <- scratch(opts, "relay-archive-" <> Relay.Id.to_string(manifest.id)) do
      try do
        archive(manifest, token, store, dir, opts)
      after
        File.rm_rf(dir)
      end
    end
  end

  defp archive(manifest, token, store, dir, opts) do
    file = Path.join(dir, "leaf.parquet")
    check = Path.join(dir, "check.parquet")

    with {:ok, columns} <- ArchiveStore.columns(manifest.leaf_name),
         names = Enum.map(columns, & &1.name),
         {:ok, written} <- write(manifest.leaf_name, columns, file, opts),
         schema = schema_json(manifest, columns, written),
         :ok <- S3.put_file(store, manifest.object_key, file, manifest.retain_until),
         :ok <- S3.put_once(store, manifest.schema_key, schema, manifest.retain_until, @json),
         :ok <- S3.get_file(store, manifest.object_key, check),
         {:ok, read} <- Relay.Parquet.verify(check, opts),
         :ok <- same(written, read, names),
         {:ok, ^schema} <- S3.get(store, manifest.schema_key),
         :ok <- ArchiveStore.verified(manifest.id, written, token),
         :ok <- ArchiveStore.drop(manifest.id, token) do
      {:ok, Map.put(written, :id, manifest.id)}
    else
      {:ok, _other} -> mismatch("schema file read back differs")
      {:error, _} = error -> error
    end
  end

  defp write(leaf, columns, file, opts) do
    names = Enum.map(columns, & &1.name)

    case ArchiveStore.with_rows(leaf, columns, &Relay.Parquet.write(file, names, &1, opts)) do
      {:ok, {:ok, written}} -> {:ok, written}
      {:ok, {:error, _} = error} -> error
      {:error, _} = error -> error
    end
  end

  defp same(%{rows: rows, digest: digest}, %{rows: rows, digest: digest, columns: names}, names),
    do: :ok

  defp same(_written, _read, _names), do: mismatch("archive read back differs")

  defp mismatch(message), do: {:error, Relay.Error.new(:archive_mismatch, message)}

  defp record_failure({:ok, _} = ok, _id), do: ok

  defp record_failure({:error, %Relay.Error{code: code}} = error, id) do
    _ = ArchiveStore.failed(id, code)
    error
  end

  defp manifest(id, leaf, until) do
    base = "#{leaf.table_name}/#{leaf.leaf_name}/#{Relay.Id.to_string(id)}"

    %{
      id: id,
      table_name: leaf.table_name,
      leaf_name: leaf.leaf_name,
      range_from: leaf.range_from,
      range_to: leaf.range_to,
      object_key: base <> ".parquet",
      schema_key: base <> ".schema.json",
      retain_until: until
    }
  end

  # OP-84
  @doc "The schema file of an archived leaf: format, table, leaf, range, migration version, columns with their PostgreSQL types and primary key positions, row count and digest."
  @spec schema_json(map(), [ArchiveStore.column()], map()) :: binary()
  def schema_json(manifest, columns, written) do
    Jason.encode!(
      Jason.OrderedObject.new([
        {"format", @schema_format},
        {"encoding", "postgresql_text"},
        {"row_digest", "sha256_canonical_rows"},
        {"table", manifest.table_name},
        {"leaf", manifest.leaf_name},
        {"range_from", DateTime.to_iso8601(manifest.range_from)},
        {"range_to", DateTime.to_iso8601(manifest.range_to)},
        {"migration_version", manifest.migration_version},
        {"columns",
         Enum.map(columns, fn column ->
           Jason.OrderedObject.new([
             {"name", column.name},
             {"type", column.type},
             {"key_position", column.key_position}
           ])
         end)},
        {"rows", written.rows},
        {"digest", Base.encode16(written.digest, case: :lower)}
      ])
    )
  end

  defp valid_store(store) do
    case S3.validate(store) do
      :ok -> :ok
      {:error, message} -> {:error, Relay.Error.new(:archive_unconfigured, message)}
    end
  end

  defp retain_days(%{retain_days: days}) when is_integer(days) and days >= 0, do: {:ok, days}

  defp retain_days(_leaf),
    do: {:error, Relay.Error.new(:retention_unknown, "no active retention_periods data set")}

  # OP-84
  # sobelow_skip ["Traversal.FileModule"]
  @doc "Creates the local scratch directory `name` under the `:tmp_dir` option (default the system temporary directory)."
  @spec scratch(keyword(), String.t()) :: {:ok, Path.t()} | {:error, Relay.Error.t()}
  def scratch(opts, name) do
    dir = Path.join(Keyword.get_lazy(opts, :tmp_dir, &System.tmp_dir!/0), name)

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} ->
        {:error, Relay.Error.new(:archive_io, "no scratch directory", %{reason: reason})}
    end
  end
end
