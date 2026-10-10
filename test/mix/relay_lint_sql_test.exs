defmodule RelayDev.Lint.SqlTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Sql

  @moduletag :tmp_dir

  describe "T-69 INV-47 OP-9 physical deletes" do
    test "INV-47: DELETE, TRUNCATE, data DROP and Ecto deletes are rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "priv/repo/migrations/1_a.exs" => """
        execute "DELETE FROM deliveries"
        execute "truncate table jobs"
        execute "DROP TABLE recipients"
        drop table(:recipients)
        remove :email
        """,
        "lib/relay/ingest/store.ex" =>
          "Repo.delete_all(q)\nRepo.delete(r)\nMulti.delete(m, :x, r)\n"
      })

      assert length(Sql.run(dir)) == 8
      assert Enum.all?(Sql.run(dir), &(&1.rule == "physical_delete"))
    end

    test "OP-9: dropping indexes, functions and policies is allowed", %{tmp_dir: dir} do
      write!(dir, %{
        "priv/repo/migrations/1_a.exs" =>
          "execute \"DROP INDEX x\"\nexecute \"DROP FUNCTION f\"\n"
      })

      assert Sql.run(dir) == []
    end

    test "T-69: an exception with a reason passes, one without a reason fails", %{tmp_dir: dir} do
      write!(dir, %{
        "lib/relay/platform/queue_store.ex" =>
          "execute(\"DELETE FROM oban_jobs WHERE id = $1\")\n",
        "conformance/catalog/sql-allow.json" =>
          ~s([{"path": "lib/relay/platform/queue_store.ex", "rule": "physical_delete", "match": "oban_jobs", "reason": "OP-12 job queue table carries ids only"}])
      })

      assert Sql.run(dir) == []

      write!(dir, %{
        "conformance/catalog/sql-allow.json" =>
          ~s([{"path": "lib/relay/platform/queue_store.ex", "rule": "physical_delete", "reason": ""}])
      })

      assert "allowlist" in rules(Sql.run(dir))
    end
  end

  describe "WF-47 TP-43 time zones" do
    test "WF-47: AT TIME ZONE is rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "lib/relay/workflow/store.ex" => "SELECT now() at time zone 'Europe/Istanbul'\n"
      })

      assert rules(Sql.run(dir)) == ["at_time_zone"]
    end
  end
end
