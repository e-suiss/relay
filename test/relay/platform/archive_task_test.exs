defmodule Relay.Platform.ArchiveTaskTest do
  use ExUnit.Case, async: true

  alias Relay.Platform.Maintenance.Archive
  alias Relay.Platform.Maintenance.ArchiveTask

  defp leaf(name), do: %{leaf_name: name}

  describe "OP-84 archive backlog" do
    test "OP-84: a waiting leaf keeps the time it was first seen and a new one takes now" do
      now = ~U[2026-11-18 12:00:00Z]
      seen = %{"a" => "2026-11-16T12:00:00Z", "gone" => "2026-11-01T00:00:00Z"}

      backlog = ArchiveTask.backlog(seen, [leaf("a"), leaf("b")], now)

      assert backlog == %{"a" => "2026-11-16T12:00:00Z", "b" => "2026-11-18T12:00:00Z"}
      assert ArchiveTask.backlog_age(backlog, now) == 2 * 86_400
      assert ArchiveTask.backlog_age(%{}, now) == 0
    end

    test "OP-84: the schema file names the columns, types, key, range, version, rows and digest" do
      manifest = %{
        table_name: "usage_records",
        leaf_name: "usage_records_p196101",
        range_from: ~U[1961-01-01 00:00:00Z],
        range_to: ~U[1961-02-01 00:00:00Z],
        migration_version: 20_270_112_000_100
      }

      columns = [
        %{name: "tenant_id", type: "uuid", key_position: 1},
        %{name: "provider", type: "text", key_position: nil}
      ]

      json = Archive.schema_json(manifest, columns, %{rows: 3, digest: <<0::256>>})

      assert %{
               "format" => "relay-archive/1",
               "table" => "usage_records",
               "migration_version" => 20_270_112_000_100,
               "rows" => 3,
               "columns" => [%{"name" => "tenant_id", "key_position" => 1}, %{"type" => "text"}]
             } = Jason.decode!(json)

      assert json == Archive.schema_json(manifest, columns, %{rows: 3, digest: <<0::256>>})
    end
  end
end
