defmodule Relay.Keys.ErasureScopeTest do
  use Relay.DataCase, async: true

  @scope "conformance/catalog/erasure-scope.json"

  defp listed_tables(json) when is_map(json) do
    own = for key <- ["table", "table_name"], is_binary(json[key]), do: json[key]
    own ++ Enum.flat_map(Map.values(json), &listed_tables/1)
  end

  defp listed_tables(json) when is_list(json), do: Enum.flat_map(json, &listed_tables/1)
  defp listed_tables(_json), do: []

  test "OP-25: every table with a tenant scope or a personal column has an erasure rule" do
    listed = @scope |> File.read!() |> Jason.decode!() |> listed_tables() |> MapSet.new()

    %{rows: rows} =
      Relay.Repo.query!("""
      SELECT DISTINCT c.relname
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
        AND (a.attname = 'tenant_id' OR a.attname ~ '_(ct|bidx)$' OR a.attname ~ '_bidx_next$')
      ORDER BY c.relname
      """)

    tables = Enum.map(rows, &hd/1)
    assert tables != []
    assert Enum.reject(tables, &MapSet.member?(listed, &1)) == []
  end

  test "OP-25: the scope lists every place outside the tables where a personal value could be copied" do
    locations = (@scope |> File.read!() |> Jason.decode!())["locations"]
    names = Enum.map(locations, & &1["location"])

    required =
      ~w(queue_args logs traces dlq analytics cold_archive backups outgoing_webhooks key_cache valkey)

    assert Enum.sort(names) == Enum.sort(required)
    assert names == Enum.uniq(names)

    for location <- locations,
        field <- ~w(store personal_data encryption subject_erasure tenant_close) do
      assert is_binary(location[field]) and location[field] != "",
             "#{location["location"]}.#{field}"
    end
  end

  test "OP-25: personal columns listed for a table are exactly its encrypted and blind index columns" do
    %{rows: rows} =
      Relay.Repo.query!("""
      SELECT c.relname, a.attname
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      WHERE n.nspname = 'relay' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
        AND a.attname ~ '_(ct|bidx|bidx_next)$'
      """)

    actual =
      Enum.group_by(rows, &hd/1, &List.last/1)
      |> Map.new(fn {t, cols} -> {t, Enum.sort(cols)} end)

    listed =
      for entry <- (@scope |> File.read!() |> Jason.decode!())["tables"],
          entry["personal_columns"] != [],
          into: %{},
          do: {entry["table"], Enum.sort(entry["personal_columns"])}

    assert listed == actual
  end
end
