defmodule Relay.Tenancy.RetentionExtensionTest do
  use Relay.DataCase, async: false

  alias Relay.Tenancy
  alias Relay.Tenancy.SettingKeys
  alias RelayTest.TenantFixture

  defp change(class, days, extra \\ %{}) do
    Map.merge(
      %{
        key: "retention." <> class,
        value: days,
        expected_version: nil,
        record_digest: TenantFixture.digest()
      },
      extra
    )
  end

  defp put(scope, change), do: Tenancy.put_setting(scope, change, TenantFixture.actor())

  defp legal_days(scope, class) do
    {:ok, days} =
      Relay.Repo.in_scope(scope, fn _status -> Tenancy.Store.retention_legal_days(class) end)

    days
  end

  describe "OP-19 DS-44 tenant retention periods" do
    test "OP-19: a retention period is a whole number of days of a record class" do
      assert SettingKeys.cast("retention.commercial_message", 4000) == {:ok, 4000}
      assert SettingKeys.cast("retention.commercial_consent", nil) == {:ok, nil}

      for value <- [0, -1, 36_526, "P10Y", 10.5] do
        assert {:error, %Relay.Error{code: :invalid_setting}} =
                 SettingKeys.cast("retention.delivery_record", value)
      end

      assert {:error, %Relay.Error{code: :unknown_setting}} =
               SettingKeys.cast("retention.traffic", 4000)
    end

    test "OP-19: a tenant extends the commercial record periods and a shorter period is refused" do
      :ok = TenantFixture.retention_periods!()
      scope = TenantFixture.tenant!().live

      for class <- ["commercial_message", "commercial_consent"] do
        legal = legal_days(scope, class)
        assert is_integer(legal) and legal > 0

        assert {:error, %Relay.Error{code: :retention_shortened, details: details}} =
                 put(scope, change(class, legal - 1))

        assert details == %{retention_class: class, legal_days: legal}
        assert {:ok, {:created, 1}} = put(scope, change(class, legal))
        assert {:ok, {:updated, 2}} = put(scope, change(class, legal + 365))

        assert {:error, %Relay.Error{code: :retention_shortened}} =
                 put(scope, change(class, legal - 1))

        assert {:ok, [{_key, value, :tenant}]} =
                 Tenancy.resolve_stored_settings(scope, nil, ["retention." <> class])

        assert value == legal + 365
      end
    end

    test "OP-19: a retention period is set at tenant level only" do
      :ok = TenantFixture.retention_periods!()
      scope = TenantFixture.tenant!().live
      legal = legal_days(scope, "commercial_message")
      subtenant = %{subtenant_id: Relay.Id.generate()}

      assert {:error, %Relay.Error{code: :invalid_setting}} =
               put(scope, change("commercial_message", legal + 1, subtenant))
    end
  end
end
