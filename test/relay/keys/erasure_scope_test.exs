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
end
