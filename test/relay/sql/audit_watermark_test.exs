defmodule Relay.Sql.AuditWatermarkTest do
  use Relay.SqlCase, async: false

  alias Relay.Repo

  test "OP-5: audit_pending returns committed records and never one from an open transaction" do
    opts = Keyword.drop(Repo.config(), [:pool, :pool_size, :ownership_timeout])
    {:ok, writer} = Postgrex.start_link(opts)
    {:ok, open} = Postgrex.start_link(opts)
    {:ok, worker} = Postgrex.start_link(opts)
    committed = id()
    in_flight = id()

    create = fn conn, tenant ->
      Postgrex.query!(conn, "SET LOCAL ROLE relay_api", [])

      Postgrex.query!(
        conn,
        "SELECT * FROM relay_ops.tenant_create($1, $2, (SELECT region FROM relay.installation), 'general', 'Europe/Istanbul', 'tr', $3, $4, $5, $6, $7)",
        [tenant, "acc_" <> Base.encode16(tenant), digest() | actor()]
      )
    end

    {:ok, _} = Postgrex.transaction(writer, &create.(&1, committed))
    Postgrex.query!(open, "BEGIN", [])
    create.(open, in_flight)

    pending = fn tenant ->
      Postgrex.query!(worker, "BEGIN", [])
      Postgrex.query!(worker, "SET LOCAL ROLE relay_worker", [])

      %{rows: [[count]]} =
        Postgrex.query!(
          worker,
          "SELECT count(*) FROM relay_ops.audit_pending('0'::xid8, 1000000) WHERE tenant_id = $1",
          [tenant]
        )

      Postgrex.query!(worker, "ROLLBACK", [])
      count
    end

    assert pending.(committed) == 1
    assert pending.(in_flight) == 0
    Postgrex.query!(open, "COMMIT", [])
    assert pending.(in_flight) == 1
  end
end
