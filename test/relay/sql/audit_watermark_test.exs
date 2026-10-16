defmodule Relay.Sql.AuditWatermarkTest do
  use Relay.SqlCase, async: false

  test "OP-5: audit_pending returns committed records and never one from an open transaction" do
    writer = connect("relay_api")
    open = connect("relay_api")
    worker = connect("relay_worker")

    committed_tenant = committed(writer, &tenant!/0)

    on(open, fn -> rows("BEGIN") end)
    in_flight = on(open, &tenant!/0)

    pending = fn tenant ->
      rolled_back(worker, fn ->
        one(
          "SELECT count(*) FROM relay_ops.audit_pending('0'::xid8, 1000000) WHERE tenant_id = $1",
          [tenant]
        )
      end)
    end

    assert pending.(committed_tenant) == 1
    assert pending.(in_flight) == 0
    on(open, fn -> rows("COMMIT") end)
    assert pending.(in_flight) == 1
  end
end
