defmodule Relay.Sql.AuditStreamTest do
  use Relay.SqlCase, async: false

  alias Relay.Repo

  @append "SELECT relay_fn.audit_append($1, $2, 'operator', $3, $4, NULL, $5, $6, $7, NULL, NULL, $8)"
  @query "SELECT id FROM relay_fn.audit_query($1, $2, NULL, NULL, 10, $3, $4, $5, $6, $7)"
  @announced """
  SELECT stream_key, seq, state, payload FROM relay.outbox_events
  WHERE event_type = 'audit_record.appended' ORDER BY seq
  """
  @fields ~w(action actor_kind audit_record_id target_id target_type)

  defp append(audit_id, reason \\ nil) do
    "appended" =
      one(@append, [
        audit_id,
        "pii.revealed",
        "person@example.com",
        "acc_op_1",
        "recipient",
        "rcp-1",
        reason,
        digest()
      ])

    audit_id
  end

  defp stream(tenant, environment \\ "test"),
    do: "audit_log:" <> Ecto.UUID.load!(tenant) <> ":" <> environment

  describe "WH-67 audit records in the outbox" do
    test "WH-67, INV-53: a record appended by the code writes one thin event with the record, the action, the actor kind and the target" do
      tenant = tenant!()
      ctx(tenant)
      before = length(rows(@announced))
      audit_id = append(id(), "asked by the customer on the phone")
      stream = stream(tenant)

      assert [[^stream, seq, "pending", payload]] = Enum.drop(rows(@announced), before)
      assert seq == before + 1

      assert payload == %{
               "audit_record_id" => Ecto.UUID.load!(audit_id),
               "action" => "pii.revealed",
               "actor_kind" => "operator",
               "target_type" => "recipient",
               "target_id" => "rcp-1"
             }
    end

    test "WH-67, WH-11: the event carries no free text and no personal data" do
      tenant = tenant!()
      ctx(tenant)
      before = length(rows(@announced))
      append(id(), "asked by the customer on the phone")

      assert [[_stream, _seq, _state, payload]] = Enum.drop(rows(@announced), before)
      assert Map.keys(payload) -- @fields == []
      text = Jason.encode!(payload)
      refute text =~ "customer"
      refute text =~ "person@example.com"
      refute text =~ "acc_op_1"
    end

    test "WH-67: a record written by a database function is announced like one appended by the code" do
      tenant = tenant!()
      ctx(tenant)
      before = length(rows(@announced))
      now = DateTime.utc_now()
      rows(@query, [DateTime.add(now, -60), DateTime.add(now, 60), digest() | actor()])

      assert [[_stream, _seq, "pending", payload]] = Enum.drop(rows(@announced), before)

      assert %{"action" => "audit_log.read", "actor_kind" => "operator"} = payload
      assert payload["target_type"] == "audit_log"
      assert Map.keys(payload) -- @fields == []
    end

    test "WH-67, WH-20: the events of an audit log are numbered without gaps, each environment on its own" do
      tenant = tenant!()
      ctx(tenant)
      before = length(rows(@announced))
      for _n <- 1..3, do: append(id())
      stream = stream(tenant)

      assert [[^stream, a, _, _], [^stream, b, _, _], [^stream, c, _, _]] =
               Enum.drop(rows(@announced), before)

      assert [a, b, c] == [before + 1, before + 2, before + 3]

      ctx(tenant, "live")
      live = length(rows(@announced))
      append(id())
      other = stream(tenant, "live")
      assert [[^other, seq, _, _]] = Enum.drop(rows(@announced), live)
      assert seq == live + 1
    end

    test "WH-67, INV-53: the event is written in the transaction of the record and leaves with it" do
      tenant = tenant!()
      ctx(tenant)
      before = length(rows(@announced))

      {:error, :rolled_back} =
        Repo.transaction(fn ->
          append(id())
          true = length(rows(@announced)) == before + 1
          Repo.rollback(:rolled_back)
        end)

      assert length(rows(@announced)) == before
    end

    test "WH-67: a record of the installation tenant, which belongs to no tenant, is not announced" do
      installation = one("SELECT relay_private.installation_tenant_id()")
      ctx(installation, "live")
      before = length(rows(@announced))
      append(id())

      assert length(rows(@announced)) == before
    end
  end
end
