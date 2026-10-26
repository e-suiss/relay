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

  describe "TN-13 T-10 T-17 tenant context, roles and queue" do
    test "TN-13: session context, missing_ok and role switching are rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "lib/relay/tenancy/store.ex" => """
        SELECT set_config('relay.tenant_id', $1, false)
        SET relay.tenant_id = 'x'
        SET SESSION relay.environment = 'live'
        SELECT current_setting('relay.tenant_id', true)
        SELECT current_setting('relay.tenant_id', missing_ok => true)
        SET ROLE relay_migrator
        SET LOCAL ROLE relay_migrator
        """
      })

      assert rules(Sql.run(dir)) |> Enum.frequencies() == %{
               "tenant_context" => 5,
               "set_role" => 2
             }
    end

    test "TN-13: a transaction-local context is allowed", %{tmp_dir: dir} do
      write!(dir, %{
        "lib/relay/tenancy/store.ex" => """
        SELECT set_config('relay.tenant_id', $1, true)
        SELECT current_setting('relay.tenant_id')::uuid
        """
      })

      assert Sql.run(dir) == []
    end

    test "T-10: LISTEN, NOTIFY and pg_notify are rejected; the Oban notifier API is not SQL", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "priv/repo/migrations/1_a.exs" =>
          "execute \"SELECT pg_notify('c', 'x')\"\nLISTEN jobs;\nNOTIFY jobs;\n",
        "lib/relay/platform/queue/notifier.ex" => "def listen(conf, channels), do: :ok\n"
      })

      assert rules(Sql.run(dir)) == ["notify", "notify", "notify"]
    end

    test "T-17: the oban queue prefix is rejected", %{tmp_dir: dir} do
      write!(dir, %{"priv/repo/migrations/1_a.exs" => ~s[Oban.Migrations.up(prefix: "oban")\n]})
      assert rules(Sql.run(dir)) == ["oban_prefix"]
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

  describe "AG-14 exact waitpoint matching" do
    test "AG-14: pattern matches on waitpoints and mailbox records are rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "priv/repo/migrations/1_a.exs" => """
        SELECT id FROM relay.waitpoints WHERE correlation_key LIKE 'order-%'
        SELECT id FROM relay.mailbox_records WHERE event_type ~ '^order'
        WHERE correlation_key ILIKE $1 AND w.id IN (SELECT id FROM relay.waitpoints)
        SELECT id FROM relay.waitpoints WHERE match_event_type SIMILAR TO 'a%'
        """
      })

      assert rules(Sql.run(dir)) == List.duplicate("correlation_match", 4)
    end

    test "AG-14: exact matches and patterns on other tables are allowed", %{tmp_dir: dir} do
      write!(dir, %{
        "priv/repo/migrations/1_a.exs" => """
        SELECT id FROM relay.waitpoints WHERE correlation_key = $1 AND match_event_type = $2
        SELECT id FROM relay.mailbox_records WHERE kind = 'early_event'
        CHECK (tag ~ '^[a-z0-9_.:-]{1,64}$')
        """
      })

      assert Sql.run(dir) == []
    end
  end
end
