defmodule Relay.Sql.AuditStreamTest do
  use Relay.SqlCase, async: false

  alias Relay.Repo

  @append "SELECT relay_fn.audit_append($1, $2, 'operator', $3, $4, NULL, $5, $6, $7, NULL, NULL, $8)"
  @query "SELECT id, action FROM relay_fn.audit_query($1, $2, $3, NULL, 10, $4, $5, $6, $7, $8)"
  @announced """
  SELECT stream_key, seq, state, payload FROM relay.outbox_events
  WHERE event_type = 'audit_record.appended' ORDER BY created_at, id
  """
  @fields ~w(action actor_kind audit_record_id target_id target_type)
  @subject ~r/^[a-z_]+:[A-Za-z0-9_.:-]{1,200}$/

  defp append(opts \\ []) do
    audit_id = id()

    "appended" =
      one(@append, [
        audit_id,
        "pii.revealed",
        "person@example.com",
        "acc_op_1",
        Keyword.get(opts, :type, "recipient"),
        Keyword.get(opts, :target, "rcp-1"),
        Keyword.get(opts, :reason),
        digest()
      ])

    audit_id
  end

  defp announced(audit_id) do
    text = Ecto.UUID.load!(audit_id)
    for [_, _, _, %{"audit_record_id" => ^text}] = row <- rows(@announced), do: row
  end

  defp count, do: length(rows(@announced))

  describe "WH-67 audit records in the outbox" do
    test "WH-67, INV-53: a record appended by the code writes one thin event with the record, the action, the actor kind and the target" do
      tenant = tenant!()
      ctx(tenant)
      audit_id = append(reason: "asked by the customer on the phone")

      assert [["audit_target:recipient:rcp-1", 1, "pending", payload]] = announced(audit_id)

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
      audit_id = append(reason: "asked by the customer on the phone")

      assert [[_stream, _seq, _state, payload]] = announced(audit_id)
      assert Map.keys(payload) -- @fields == []
      text = Jason.encode!(payload)
      refute text =~ "customer"
      refute text =~ "person@example.com"
      refute text =~ "acc_op_1"
    end

    test "WH-67: a record written by a database function is announced like one appended by the code" do
      tenant = tenant!()
      ctx(tenant)
      key = Ecto.UUID.load!(tenant_key!("data"))
      stream = "audit_target:tenant_key:" <> key

      assert [[^stream, 1, "pending", payload] | _more] =
               Enum.filter(rows(@announced), &(hd(&1) == stream))

      assert %{"target_type" => "tenant_key", "target_id" => ^key} = payload
      assert Map.keys(payload) -- @fields == []
    end

    test "WH-67, WH-20: seq counts the records of one target; another target, a record without one and the other environment count on their own" do
      tenant = tenant!()
      ctx(tenant)
      same = for _n <- 1..3, do: append()

      heads = for audit_id <- same, [stream, seq, _, _] <- announced(audit_id), do: {stream, seq}
      assert heads == for(seq <- 1..3, do: {"audit_target:recipient:rcp-1", seq})

      assert [["audit_target:recipient:rcp-2", 1, _, _]] = announced(append(target: "rcp-2"))

      bare = append(type: nil, target: nil)
      alone = "audit_record:" <> Ecto.UUID.load!(bare)
      assert [[^alone, 1, _, payload]] = announced(bare)
      refute Map.has_key?(payload, "target_type")

      assert [[digest, 1, _, %{"target_id" => "a b/ç"}]] = announced(append(target: "a b/ç"))
      assert "audit_target_digest:" <> _ = digest
      assert digest =~ @subject
      assert [[^digest, 2, _, _]] = announced(append(target: "a b/ç"))

      ctx(tenant, "live")
      assert [["audit_target:recipient:rcp-1", 1, _, _]] = announced(append())
    end

    test "WH-67, TN-50: a reading of the audit log is recorded and not announced" do
      tenant = tenant!()
      ctx(tenant)
      before = count()
      now = DateTime.utc_now()
      window = [DateTime.add(now, -3600), DateTime.add(now, 3600)]
      rows(@query, window ++ [nil, digest() | actor()])

      assert count() == before

      assert [[_id, "audit_log.read"]] =
               rows(@query, window ++ ["audit_log.read", digest() | actor()])

      assert count() == before
    end

    test "WH-67, INV-53: the event is written in the transaction of the record and leaves with it" do
      tenant = tenant!()
      ctx(tenant)
      before = count()

      {:error, :rolled_back} =
        Repo.transaction(fn ->
          append()
          true = count() == before + 1
          Repo.rollback(:rolled_back)
        end)

      assert count() == before
    end

    test "WH-67: a record of the installation tenant, which belongs to no tenant, is not announced" do
      installation = one("SELECT relay_private.installation_tenant_id()")
      ctx(installation, "live")
      before = count()
      append()

      assert count() == before
    end
  end
end
