defmodule Relay.Keys.RetentionTest do
  use ExUnit.Case, async: true

  alias Relay.Keys.Erasure

  test "OP-17: a receipt day key may be destroyed seven days after its day" do
    day = ~D[2026-10-01]
    refute Erasure.receipt_key_due?(day, ~D[2026-10-07])
    assert Erasure.receipt_key_due?(day, ~D[2026-10-08])
    assert Erasure.receipt_key_due?(day, ~D[2027-01-01])
  end
end

defmodule Relay.Keys.RetentionDatabaseTest do
  use Relay.MaintenanceCase, async: false

  alias Relay.Tenancy.Retention

  test "OP-16: the sweep destroys receipt day keys a week old and keeps younger ones" do
    committed(fn ->
      tenant = tenant!()
      today = Date.utc_today()

      {old, young} =
        scoped(tenant.id, "live", fn ->
          {tenant_key!("receipt_day", Date.add(today, -8)),
           tenant_key!("receipt_day", Date.add(today, -1))}
        end)

      assert {:ok, %{"results" => results}, _delay} =
               Retention.run(%{name: "retention_sweep", node: "t", fencing_token: 1, state: nil})

      assert Map.get(results, "destroyed", 0) >= 1

      states =
        scoped(tenant.id, "live", fn ->
          "SELECT id, state, wrapped_key IS NULL FROM relay.tenant_keys WHERE id = ANY($1)"
          |> rows!([[old, young]])
          |> Map.new(fn [id, state, gone] -> {id, {state, gone}} end)
        end)

      assert states[old] == {"destroyed", true}
      assert states[young] == {"active", false}
    end)
  end
end
