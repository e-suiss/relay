defmodule Relay.Platform.Maintenance.Restore do
  @moduledoc """
  Restores an archived leaf for reading: downloads its Parquet object from the archive store, checks the row count and digest against the manifest, and loads the rows into a new `restore_…` schema with `COPY` into a staging table, a matching `CHECK`, `ATTACH` to a partitioned copy of the table and a seal that makes the leaf read-only. The live `relay` schema is never touched. Used by the operator command `bin/archive restore` and by the region acceptance drill.
  """

  alias Relay.ObjectStore.S3
  alias Relay.Platform.Maintenance.Archive
  alias Relay.Platform.Maintenance.ArchiveStore
  alias Relay.Platform.Maintenance.ArchiveTask

  # OP-84
  # OP-14 (6)
  @doc "Restores the archived leaf of manifest `id` into `schema` (`restore_…`). Options: `:tmp_dir` and the options of `Relay.Parquet`."
  @spec run(Relay.Id.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Relay.Error.t()}
  def run(id, schema, opts \\ []) do
    store = ArchiveTask.store()

    with :ok <- valid_store(store),
         {:ok, manifest} <- ArchiveStore.manifest(id),
         :ok <- archived(manifest),
         {:ok, dir} <- Archive.scratch(opts, "relay-restore-" <> Relay.Id.to_string(id)) do
      try do
        restore(store, manifest, schema, Path.join(dir, "leaf.parquet"), opts)
      after
        File.rm_rf(dir)
      end
    end
  end

  defp restore(store, manifest, schema, file, opts) do
    loader = &load(file, opts, &1)

    with :ok <- S3.get_file(store, manifest.object_key, file),
         {:ok, read} <- Relay.Parquet.verify(file, opts),
         :ok <- matches(manifest, read),
         {:ok, rows} <- ArchiveStore.restore(schema, manifest, read.columns, loader) do
      {:ok, %{schema: schema, table: manifest.table_name, leaf: manifest.leaf_name, rows: rows}}
    end
  end

  defp load(file, opts, {acc, push}) do
    fold = fn rows, {state, count} -> {push.(rows, state), count + length(rows)} end

    case Relay.Parquet.reduce(file, {acc, 0}, fold, opts) do
      {:ok, _columns, {state, count}} -> {:ok, state, count}
      {:error, _} = error -> error
    end
  end

  defp archived(%{status: status}) when status in ["verified", "archived"], do: :ok

  defp archived(_manifest),
    do: {:error, Relay.Error.new(:archive_refused, "the manifest has no verified archive")}

  defp matches(%{rows: rows, digest: digest}, %{rows: rows, digest: digest}), do: :ok

  defp matches(_manifest, _read),
    do: {:error, Relay.Error.new(:archive_mismatch, "the archived object differs")}

  defp valid_store(store) do
    case S3.validate(store) do
      :ok -> :ok
      {:error, message} -> {:error, Relay.Error.new(:archive_unconfigured, message)}
    end
  end
end
