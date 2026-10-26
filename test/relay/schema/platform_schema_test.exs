defmodule Relay.Schema.PlatformSchemaTest do
  use Relay.DataCase, async: true

  alias Relay.Platform.Queue.PrunerStore
  alias Relay.Repo

  @job_tables ~w(oban_jobs oban_peers)
  @golden "queue_prune_policies.txt"

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp domain(name) do
    [[definition]] =
      rows(
        """
        SELECT pg_get_constraintdef(con.oid) FROM pg_constraint con
        JOIN pg_type t ON t.oid = con.contypid JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'relay' AND t.typname = $1
        """,
        [name]
      )

    definition
  end

  defp values(definition), do: for([_, v] <- Regex.scan(~r/'([a-z0-9_]+)'/, definition), do: v)

  defp ephemeral_tables do
    rows("""
    SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'relay_queue' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
    ORDER BY 1
    """)
    |> List.flatten()
    |> Kernel.--(@job_tables)
  end

  defp policies(schema, table) do
    rows(
      """
      SELECT p.polname::text, p.polcmd::text,
        ARRAY(SELECT CASE r WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(r)::text END
              FROM unnest(p.polroles) AS r ORDER BY 1),
        pg_get_expr(p.polqual, p.polrelid), pg_get_expr(p.polwithcheck, p.polrelid)
      FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = $2 ORDER BY 1
      """,
      [schema, table]
    )
  end

  describe "T-31 CH-7 T-29 C-4 platform domains" do
    test "T-31: the lane domain holds the four lanes" do
      assert values(domain("lane")) == ~w(l0 l1 l2 l3)
    end

    test "CH-7: the failure class domain holds the eight failure classes" do
      assert values(domain("failure_class")) ==
               ~w(transient permanent_target permanent_content policy quota auth sender_config unknown)
    end

    test "T-29: the dead-letter class domain holds the four classes" do
      assert values(domain("dlq_class")) == ~w(permanent quality_alarm exhausted budget_denied)
    end

    test "C-4: the rule id domain accepts dotted and colon segments up to 128 characters" do
      for ok <- ["load_shed.l1", "admission.lmax.l2", "rate_limit.backend_unavailable", "a:B-1"],
          do: assert(rows("SELECT $1::text::relay.rule_id", [ok]) == [[ok]])

      for bad <- ["Load_shed", "1abc", "a..b", "a.", "", String.duplicate("a", 129)] do
        assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
                 Repo.transaction(fn ->
                   case Repo.query("SELECT $1::text::relay.rule_id", [bad]) do
                     {:ok, result} -> result
                     {:error, error} -> Repo.rollback(error)
                   end
                 end)
      end
    end
  end

  describe "OP-74 ephemeral queue tables" do
    test "OP-74: every relay_queue table besides the job queue is pruned by the queue cleaner" do
      assert ephemeral_tables() == Enum.sort(PrunerStore.ephemeral_tables())
    end

    test "OP-74: ephemeral tables force row level security and carry the tenant template" do
      [[_, _, _, template, _]] = policies("relay", "subtenants")

      for table <- ephemeral_tables() do
        [[rls, force]] =
          rows(
            "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE oid = format('relay_queue.%I', $1::text)::regclass",
            [table]
          )

        assert rls and force, table

        assert [_, _, ["#{table}_scope", "*", ["PUBLIC"], ^template, ^template]] =
                 policies("relay_queue", table)
      end
    end

    test "OP-74: the two prune policies of every ephemeral table are the golden text" do
      lines =
        for table <- ephemeral_tables(),
            [name, cmd, roles, using, _check] <- policies("relay_queue", table),
            name != "#{table}_scope" do
          assert name in ["#{table}_prune", "#{table}_prune_read"], name
          assert roles == ["relay_queue"], name
          "#{table} #{name} #{cmd} #{Enum.join(roles, ",")} #{using}\n"
        end

      Relay.Golden.assert_golden(@golden, lines)
    end

    test "OP-74: the application group holds no privilege on an ephemeral table" do
      for table <- ephemeral_tables(), privilege <- ~w(SELECT INSERT UPDATE DELETE TRUNCATE) do
        refute rows(
                 "SELECT has_table_privilege('relay_app', format('relay_queue.%I', $1::text)::regclass, $2)",
                 [table, privilege]
               ) == [[true]],
               "#{table} #{privilege}"
      end
    end
  end
end
