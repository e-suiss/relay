defmodule Relay.Keys.SubjectKeyTest do
  use ExUnit.Case, async: true

  alias Relay.Keys.Erasure

  test "OP-18: classes under an obligation are restricted, every other subject class is destroyed" do
    assert {:ok, %{destroy: destroy, restrict: ["commercial_consent", "commercial_message"]}} =
             Erasure.plan(["commercial_message", "commercial_consent"])

    assert Enum.sort(destroy ++ ["commercial_consent", "commercial_message"]) ==
             Enum.sort(Erasure.subject_classes())

    assert {:ok, %{destroy: all, restrict: []}} = Erasure.plan([])
    assert all == Erasure.subject_classes()
    assert {:error, %{code: :invalid_argument}} = Erasure.plan(["audit"])
  end
end

defmodule Relay.Keys.SubjectKeyDatabaseTest do
  use Relay.DataCase, async: true

  import Mox

  import Relay.MaintenanceCase,
    only: [tenant!: 0, scoped: 3, recipient!: 2, subject_key!: 3, rows!: 2]

  alias Relay.Keys.Erasure
  alias Relay.Tenancy.KeyProviderMock

  setup :verify_on_exit!

  @actor %{kind: "system", ref: "relay:test", on_behalf_of: "relay"}

  setup do
    tenant = tenant!()
    keys = tenant.keys["live"]
    dek = :crypto.strong_rand_bytes(32)
    {recipient, _} = scoped(tenant.id, "live", fn -> recipient!(keys, dek) end)
    %{tenant: tenant, keys: keys, recipient: recipient}
  end

  defp field_scope(tenant, recipient),
    do: %{
      tenant_id: tenant.id,
      environment: "live",
      subject_id: recipient,
      retention_class: :recipient_profile
    }

  defp stub_provider(tenant) do
    stub(KeyProviderMock, :data_key, fn %{subject_id: recipient} ->
      scoped(tenant.id, "live", fn -> profile_key(recipient) end)
    end)
  end

  defp profile_key(recipient) do
    case rows!(
           "SELECT wrapped_dek FROM relay.subject_keys WHERE recipient_id = $1 AND retention_class = 'recipient_profile'",
           [recipient]
         ) do
      [[dek]] when is_binary(dek) -> {:ok, Relay.Redacted.wrap(dek)}
      _ -> {:error, Relay.Error.new(:key_destroyed, "data key destroyed")}
    end
  end

  test "C-86: after the data key is destroyed the field no longer decrypts and the row stays",
       %{tenant: tenant, recipient: recipient} do
    stub_provider(tenant)
    scope = field_scope(tenant, recipient)
    opts = [key_provider: KeyProviderMock]

    {:ok, stored} = Relay.Tenancy.encrypt_field(scope, "ada@example.com", opts)
    assert {:ok, _} = Relay.Tenancy.decrypt_field(scope, stored, opts)

    assert {:ok, :erased, 0} =
             Erasure.erase_subject(
               %{tenant_id: tenant.id, environment: "live"},
               recipient,
               "dsr-c86",
               [],
               @actor
             )

    assert {:error, %{code: :key_destroyed}} = Relay.Tenancy.decrypt_field(scope, stored, opts)

    assert scoped(tenant.id, "live", fn ->
             rows!("SELECT count(*) FROM relay.recipients WHERE id = $1", [recipient])
           end) == [[1]]
  end

  test "OP-18: a subject has one data key per retention class",
       %{tenant: tenant, keys: keys, recipient: recipient} do
    scoped(tenant.id, "live", fn ->
      _ = subject_key!(recipient, "delivery_record", keys.wrap)

      assert [["exists", _]] =
               rows!(
                 "SELECT result, subject_key_id FROM relay_fn.subject_key_create($1, $2, $3, $4, $5)",
                 [
                   Relay.Id.generate(),
                   recipient,
                   "delivery_record",
                   :crypto.strong_rand_bytes(32),
                   keys.wrap
                 ]
               )

      assert rows!(
               "SELECT count(*) FROM relay.subject_keys WHERE recipient_id = $1 AND retention_class = 'delivery_record'",
               [recipient]
             ) == [[1]]
    end)
  end
end
