defmodule Relay.Keys.SubjectKeyTest do
  use ExUnit.Case, async: true

  alias Relay.Keys.Erasure

  defp row(region, sector, class, days),
    do: %{"region" => region, "sector" => sector, "retention_class" => class, "days" => days}

  test "OP-18: classes under an obligation are restricted, every other subject class is destroyed" do
    content = %{
      "periods" => [
        row("tr", "general", "commercial_message", 3653),
        row("tr", "general", "commercial_consent", 3653),
        row("tr", "general", "audit", 400),
        row("tr", "bank", "delivery_record", 730),
        row("eu", "general", "delivery_record", 730)
      ]
    }

    assert {:ok, %{destroy: destroy, restrict: ["commercial_consent", "commercial_message"]}} =
             Erasure.plan(content, "tr", "general")

    assert Enum.sort(destroy ++ ["commercial_consent", "commercial_message"]) ==
             Enum.sort(Erasure.subject_classes())

    assert {:ok, %{restrict: ["delivery_record"]}} = Erasure.plan(content, "tr", "bank")
  end

  test "TN-67 (2): the obligated classes come from the data set for the tenant's region and sector" do
    content = %{
      "periods" => [
        row("tr", "general", "delivery_record", 0),
        row("tr", "general", "audit", 400)
      ]
    }

    assert {:ok, %{destroy: all, restrict: []}} = Erasure.plan(content, "tr", "general")
    assert all == Erasure.subject_classes()

    assert {:error, %{code: :retention_rule_missing}} = Erasure.plan(content, "tr", "insurance")
    assert {:error, %{code: :retention_rule_missing}} = Erasure.plan(content, "us", "general")
    assert {:error, %{code: :invalid_dataset}} = Erasure.plan(%{}, "tr", "general")

    {:ok, v2} = File.read("priv/datasets/retention_periods/v2.json")

    for region <- ~w(tr eu us), sector <- ~w(general payment bank ecommerce) do
      assert {:ok, %{restrict: restrict}} = Erasure.plan(Jason.decode!(v2), region, sector)
      assert restrict == ["delivery_record", "commercial_consent", "commercial_message"]
    end
  end

  test "TN-67 (2): the caller cannot pass the obligated classes" do
    Code.ensure_loaded!(Erasure)
    refute function_exported?(Erasure, :erase_subject, 5)
    assert function_exported?(Erasure, :erase_subject, 4)
    refute function_exported?(Erasure, :plan, 1)
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

  @actor %Relay.Actor{kind: :system, ref: "relay:test", on_behalf_of_ref: "relay"}

  setup do
    :ok = RelayTest.TenantFixture.retention_periods!()
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
      retention_class: :recipient_profile,
      table: "recipients",
      column: "external_id_ct"
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
               Relay.Scope.new!(tenant.id, :live),
               recipient,
               "dsr-c86",
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
