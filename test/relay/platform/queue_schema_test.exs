defmodule Relay.Platform.QueueSchemaTest do
  use Relay.DataCase, async: true

  alias Relay.Repo

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  test "T-17: the queue tables live in the oban schema, not in the application schema" do
    tables =
      rows(
        "SELECT table_schema, table_name FROM information_schema.tables WHERE table_name LIKE 'oban_%'"
      )

    assert ["oban", "oban_jobs"] in tables
    assert ["oban", "oban_peers"] in tables
    refute Enum.any?(tables, fn [schema, _] -> schema == "public" end)
  end

  test "T-17: the queue schema is migrated to the pinned version" do
    assert Oban.Migration.migrated_version(repo: Repo, prefix: "oban") == 14
  end

  test "T-12: the leadership table keeps its primary key" do
    constraints =
      rows("""
      SELECT tc.constraint_type, kcu.column_name
      FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu
        ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
      WHERE tc.table_schema = 'oban' AND tc.table_name = 'oban_peers'
      """)

    assert ["PRIMARY KEY", "name"] in constraints
  end

  test "T-10: no LISTEN/NOTIFY trigger exists on the job table" do
    triggers =
      rows(
        "SELECT tgname FROM pg_trigger WHERE tgrelid = 'oban.oban_jobs'::regclass AND NOT tgisinternal"
      )

    assert triggers == []

    functions =
      rows("""
      SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'oban' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ILIKE '%pg_notify%'
      """)

    assert functions == []
  end
end
