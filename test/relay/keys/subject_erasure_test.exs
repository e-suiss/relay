defmodule Relay.Keys.SubjectErasureTest do
  use Relay.DataCase, async: true

  import Relay.MaintenanceCase,
    only: [
      tenant!: 0,
      scoped: 3,
      recipient!: 1,
      subject_key!: 3,
      pending_delivery!: 1,
      rows!: 2,
      digest: 0,
      actor: 0
    ]

  alias Relay.Keys.Erasure

  @actor %Relay.Actor{
    kind: :operator,
    ref: "op-1",
    on_behalf_of_ref: "op-1",
    access_record_ref: "acc-rec-1"
  }

  setup do
    tenant = tenant!()
    keys = tenant.keys["live"]
    scope = Relay.Scope.new!(tenant.id, :live)

    {recipient, delivery} =
      scoped(tenant.id, "live", fn ->
        {recipient, _profile_key} = recipient!(keys)
        _ = subject_key!(recipient, "delivery_record", keys.wrap)
        _ = subject_key!(recipient, "preference", keys.wrap)
        {_notification, delivery} = pending_delivery!(recipient)
        {recipient, delivery}
      end)

    %{scope: scope, recipient: recipient, delivery: delivery}
  end

  defp key_states(scope, recipient) do
    scoped(scope.tenant_id, scope.environment, fn ->
      "SELECT retention_class, state, wrapped_dek IS NULL FROM relay.subject_keys WHERE recipient_id = $1"
      |> rows!([recipient])
      |> Map.new(fn [class, state, gone] -> {class, {state, gone}} end)
    end)
  end

  test "MKT-13: pending deliveries are cancelled with the erasure rule and the data keys are destroyed",
       %{scope: scope, recipient: recipient, delivery: delivery} do
    assert {:ok, :erased, 1} =
             Erasure.erase_subject(scope, recipient, "dsr-1", ["delivery_record"], @actor)

    scoped(scope.tenant_id, scope.environment, fn ->
      assert rows!(
               "SELECT failure_kind, failure_rule_id FROM relay.deliveries WHERE id = $1",
               [delivery]
             ) == [["cancelled", "subject_erasure"]]

      assert rows!(
               "SELECT state, external_id_bidx IS NULL, deleted_reason FROM relay.recipients WHERE id = $1",
               [recipient]
             ) == [["deleted", true, "erasure"]]

      assert [[destroyed, restricted, 1, true]] =
               rows!(
                 """
                 SELECT destroyed_classes, restricted_classes, cancelled_deliveries,
                        backup_copies_expire_at = created_at + interval '35 days'
                 FROM relay.erasure_log WHERE recipient_id = $1
                 """,
                 [recipient]
               )

      assert "recipient_profile" in destroyed and "preference" in destroyed
      assert restricted == ["delivery_record"]
    end)

    assert key_states(scope, recipient) == %{
             "recipient_profile" => {"destroyed", true},
             "preference" => {"destroyed", true},
             "delivery_record" => {"restricted", false}
           }
  end

  test "OP-17: an active legal hold stops the erasure and changes nothing",
       %{scope: scope, recipient: recipient} do
    scoped(scope.tenant_id, scope.environment, fn ->
      assert [["placed"]] =
               rows!(
                 "SELECT relay_fn.legal_hold_place($1, $2, $3, $4, $5, $6, $7, $8, $9)",
                 [
                   Relay.Id.generate(),
                   "recipient",
                   recipient,
                   "regulator request",
                   digest() | actor()
                 ]
               )
    end)

    before = key_states(scope, recipient)
    assert {:ok, :held, 0} = Erasure.erase_subject(scope, recipient, "dsr-2", [], @actor)
    assert key_states(scope, recipient) == before
    assert Enum.all?(before, fn {_class, {state, _}} -> state == "active" end)
  end

  test "OP-24: erasing an erased subject is reported and changes nothing more",
       %{scope: scope, recipient: recipient} do
    assert {:ok, :erased, 1} = Erasure.erase_subject(scope, recipient, "dsr-3", [], @actor)

    assert {:ok, :already_erased, _} =
             Erasure.erase_subject(scope, recipient, "dsr-3", [], @actor)

    assert {:ok, :not_found, 0} =
             Erasure.erase_subject(scope, Relay.Id.generate(), "dsr-4", [], @actor)
  end
end
