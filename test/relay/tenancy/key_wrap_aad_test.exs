defmodule Relay.Tenancy.KeyWrapAadTest do
  use ExUnit.Case, async: true

  alias Relay.Tenancy.Keyring

  @tenant Base.decode16!("01890A5DAC96774BBCCEB302099A8057")
  @key Base.decode16!("01890A5DAC967C4A8A2F7C3B8E5D1F00")
  @recipient Base.decode16!("01890A5DAC967D119F00112233445566")

  defp hex(binary), do: Base.encode16(binary, case: :lower)

  describe "TN-67 (5) wrapping associated data" do
    test "TN-67 (5): a tenant key is bound to [1, tenant, environment, key id, purpose]" do
      scope = Relay.Scope.new!(@tenant, :live)
      assert {:ok, aad} = Keyring.tenant_key_aad(scope, @key, "dek_wrap")

      assert hex(aad) ==
               "85" <>
                 "01" <>
                 "50" <>
                 "01890a5dac96774bbcceb302099a8057" <>
                 "64" <>
                 "6c697665" <>
                 "50" <>
                 "01890a5dac967c4a8a2f7c3b8e5d1f00" <>
                 "68" <>
                 "64656b5f77726170"

      assert {:ok, test_aad} =
               Keyring.tenant_key_aad(Relay.Scope.new!(@tenant, :test), @key, "data")

      assert hex(test_aad) ==
               "850150" <>
                 "01890a5dac96774bbcceb302099a8057" <>
                 "6474657374" <>
                 "50" <>
                 "01890a5dac967c4a8a2f7c3b8e5d1f00" <>
                 "6464617461"
    end

    test "TN-67 (5): a subject key is bound to [1, tenant, environment, recipient, class, wrapping key id]" do
      scope = Relay.Scope.new!(@tenant, :live)
      aad = Keyring.subject_key_aad(scope, @recipient, "recipient_profile", @key)

      assert hex(aad) ==
               "86" <>
                 "01" <>
                 "50" <>
                 "01890a5dac96774bbcceb302099a8057" <>
                 "64" <>
                 "6c697665" <>
                 "50" <>
                 "01890a5dac967d119f00112233445566" <>
                 "71" <>
                 "726563697069656e745f70726f66696c65" <>
                 "50" <>
                 "01890a5dac967c4a8a2f7c3b8e5d1f00"
    end

    test "TN-67 (5): the KEK reference is pkcs11:object=<label>" do
      assert Relay.Keys.uri("kek-tr-1") == "pkcs11:object=kek-tr-1"
      assert Relay.Keys.label("pkcs11:object=kek-tr-1") == {:ok, "kek-tr-1"}
    end
  end
end
