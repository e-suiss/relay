defmodule Relay.Keys.LegalEvidenceTest do
  use Relay.DataCase, async: true

  import Relay.MaintenanceCase,
    only: [tenant!: 0, scoped: 3, recipient!: 1, subject_key!: 3, pending_delivery!: 1, rows!: 2]

  alias Relay.Keys.Erasure
  alias Relay.Tenancy.Keyring

  @actor %Relay.Actor{
    kind: :operator,
    ref: "op-1",
    on_behalf_of_ref: "op-1",
    access_record_ref: "acc-rec-1"
  }

  setup do
    RelayTest.TenantFixture.retention_periods!()
    tenant = tenant!()
    keys = tenant.keys["live"]

    {recipient, delivery} =
      scoped(tenant.id, "live", fn ->
        {recipient, _profile_key} = recipient!(keys)
        _ = subject_key!(recipient, "commercial_message", keys.wrap)
        _ = subject_key!(recipient, "notification_content", keys.wrap)
        {_notification, delivery} = pending_delivery!(recipient)
        {recipient, delivery}
      end)

    %{scope: Relay.Scope.new!(tenant.id, :live), recipient: recipient, delivery: delivery}
  end

  defp key(scope, recipient, class) do
    Keyring.data_key(%{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: recipient,
      retention_class: class
    })
  end

  test "IN-45: legal evidence stays under its own restricted key, nothing else readable",
       %{scope: scope, recipient: recipient, delivery: delivery} do
    assert {:ok, :erased, 1} = Erasure.erase_subject(scope, recipient, "dsr-in45", @actor)

    assert {:error, %Relay.Error{code: :data_key_restricted}} =
             key(scope, recipient, "commercial_message")

    for class <- ["recipient_profile", "notification_content"] do
      assert {:error, %Relay.Error{code: :data_key_destroyed}} = key(scope, recipient, class)
    end

    scoped(scope.tenant_id, scope.environment, fn ->
      assert [["deleted", true, true]] =
               rows!(
                 """
                 SELECT state, external_id_bidx IS NULL, external_id_key_id = (
                   SELECT id FROM relay.subject_keys
                   WHERE recipient_id = $1 AND retention_class = 'recipient_profile')
                 FROM relay.recipients WHERE id = $1
                 """,
                 [recipient]
               )

      assert [["cancelled", "erasure.subject"]] =
               rows!(
                 "SELECT failure_kind, failure_rule_id FROM relay.deliveries WHERE id = $1",
                 [delivery]
               )

      assert [[restricted]] =
               rows!(
                 "SELECT restricted_classes FROM relay.erasure_log WHERE recipient_id = $1",
                 [recipient]
               )

      assert "commercial_message" in restricted
      refute "recipient_profile" in restricted
      refute "notification_content" in restricted
    end)
  end
end
