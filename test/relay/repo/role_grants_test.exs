defmodule Relay.Repo.RoleGrantsTest do
  use Relay.DataCase, async: true

  alias Relay.Repo

  @schemas ["relay", "relay_fn", "relay_ops", "relay_private", "relay_queue"]
  @golden "db_grants.txt"

  defp grants do
    Repo.query!(
      """
      SELECT 'schema ' || n.nspname,
        CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END,
        string_agg(a.privilege_type, ',' ORDER BY a.privilege_type)
      FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a
      WHERE n.nspname::text = ANY($1::text[]) AND a.grantee <> n.nspowner
      GROUP BY 1, 2
      UNION ALL
      SELECT CASE c.relkind WHEN 'S' THEN 'sequence ' ELSE 'table ' END || n.nspname || '.' || c.relname,
        CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END,
        string_agg(a.privilege_type, ',' ORDER BY a.privilege_type)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      CROSS JOIN LATERAL aclexplode(c.relacl) a
      WHERE n.nspname::text = ANY($1::text[]) AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
        AND NOT c.relispartition AND a.grantee <> c.relowner
      GROUP BY 1, 2
      """,
      [@schemas]
    ).rows
    |> Enum.map(&Enum.join(&1, " "))
    |> Enum.sort()
  end

  describe "OP-9 grants" do
    test "OP-9: the grants of every role on schemas, tables and sequences are the golden list" do
      actual = grants()

      expected =
        Path.join("test/golden", @golden) |> File.read!() |> String.split("\n", trim: true)

      if System.get_env("GOLDEN_UPDATE") != "1", do: assert(actual == expected)
      Relay.Golden.assert_golden(@golden, Enum.map(actual, &(&1 <> "\n")))
    end

    test "OP-9: the application group holds no write on a record table and no delete anywhere" do
      writes =
        Repo.query!("""
        SELECT n.nspname::text, c.relname::text, p
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace,
          unnest(ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) AS p
        WHERE n.nspname LIKE 'relay%' AND c.relkind IN ('r', 'p')
          AND has_table_privilege('relay_app', c.oid, p)
          AND NOT (n.nspname = 'relay_queue' AND p IN ('INSERT', 'UPDATE'))
        """).rows

      assert writes == []
    end

    test "OP-12: only the queue login deletes, and only queue rows" do
      deleters =
        Repo.query!("""
        SELECT r.rolname::text, n.nspname::text || '.' || c.relname::text
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, pg_roles r
        WHERE n.nspname LIKE 'relay%' AND c.relkind IN ('r', 'p') AND r.rolname LIKE 'relay\\_%'
          AND r.rolname <> 'relay_migrator' AND has_table_privilege(r.oid, c.oid, 'DELETE')
        ORDER BY 1, 2
        """).rows

      ephemeral =
        for table <- Relay.Platform.Queue.PrunerStore.ephemeral_tables(),
            do: ["relay_queue", "relay_queue." <> table]

      assert deleters ==
               Enum.sort(
                 [
                   ["relay_queue", "relay_queue.oban_jobs"],
                   ["relay_queue", "relay_queue.oban_peers"]
                 ] ++ ephemeral
               )
    end

    test "OP-9: only the maintenance and archive logins bypass row level security, and no role is a superuser" do
      roles =
        Repo.query!("""
        SELECT rolname::text, rolsuper, rolbypassrls, rolcanlogin FROM pg_roles
        WHERE rolname LIKE 'relay\\_%' ORDER BY 1
        """).rows

      assert roles == [
               ["relay_api", false, false, true],
               ["relay_app", false, false, false],
               ["relay_archive", false, true, true],
               ["relay_maint", false, true, true],
               ["relay_migrator", false, false, true],
               ["relay_owner", false, false, false],
               ["relay_queue", false, false, true],
               ["relay_report", false, false, true],
               ["relay_worker", false, false, true]
             ]
    end

    test "OP-9: memberships are the application group and the escape hatch to the migrator" do
      memberships =
        Repo.query!("""
        SELECT pg_get_userbyid(m.roleid)::text, pg_get_userbyid(m.member)::text, m.inherit_option, m.set_option
        FROM pg_auth_members m
        WHERE pg_get_userbyid(m.roleid) LIKE 'relay\\_%' AND pg_get_userbyid(m.member) LIKE 'relay\\_%'
        ORDER BY 1, 2
        """).rows

      assert memberships == [
               ["relay_app", "relay_api", true, true],
               ["relay_app", "relay_worker", true, true],
               ["relay_migrator", "relay_archive", false, true],
               ["relay_migrator", "relay_maint", false, true],
               ["relay_owner", "relay_migrator", false, true]
             ]
    end
  end
end
