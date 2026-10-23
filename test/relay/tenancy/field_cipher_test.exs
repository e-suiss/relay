defmodule Relay.Tenancy.FieldCipherTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Relay.Redacted
  alias Relay.Tenancy.KeyProviderMock

  setup :verify_on_exit!

  @key :binary.copy(<<7>>, 32)
  @tenant <<1::128>>
  @subject <<2::128>>
  @scope %{
    tenant_id: @tenant,
    environment: :live,
    subject_id: @subject,
    retention_class: :recipient_profile,
    table: "recipients",
    column: "external_id_ct"
  }
  @opts [key_provider: KeyProviderMock]

  defp with_key(key \\ @key),
    do: stub(KeyProviderMock, :data_key, fn _ -> {:ok, Redacted.wrap(key)} end)

  defp encrypt(plaintext, scope \\ @scope),
    do: Relay.Tenancy.encrypt_field(scope, plaintext, @opts)

  defp decrypt(stored, scope \\ @scope), do: Relay.Tenancy.decrypt_field(scope, stored, @opts)

  describe "TN-33 OP-18 field encryption" do
    property "TN-33: encrypted fields decrypt to the original value" do
      with_key()

      check all plaintext <- binary() do
        assert {:ok, stored} = encrypt(plaintext)
        assert {:ok, redacted} = decrypt(stored)
        assert Redacted.expose(redacted) == plaintext
      end
    end

    test "TN-66: the stored form is format, nonce, ciphertext and tag; the associated data binds format, tenant, environment, subject, class, table and column" do
      with_key()
      previous = Application.fetch_env!(:relay, :random)
      Application.put_env(:relay, :random, Relay.RandomMock)
      on_exit(fn -> Application.put_env(:relay, :random, previous) end)

      nonce = :binary.copy(<<9>>, 12)
      expect(Relay.RandomMock, :bytes, fn 12 -> nonce end)

      assert {:ok, <<1, ^nonce::binary-12, rest::binary>>} = encrypt("ayse@example.com")

      aad =
        <<0x87, 0x01, 0x50, @tenant::binary, 0x64, "live", 0x50, @subject::binary, 0x71,
          "recipient_profile", 0x6A, "recipients", 0x6E, "external_id_ct">>

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, @key, nonce, "ayse@example.com", aad, 16, true)

      assert rest == ciphertext <> tag
    end

    test "TN-33: every encryption draws a fresh nonce" do
      with_key()
      {:ok, <<1, a::binary-12, _::binary>>} = encrypt("same")
      {:ok, <<1, b::binary-12, _::binary>>} = encrypt("same")
      refute a == b
    end

    test "OP-18: the data key is requested for the subject and retention class" do
      expect(KeyProviderMock, :data_key, 2, fn scope ->
        assert scope == %{@scope | retention_class: :notification_content}
        {:ok, Redacted.wrap(@key)}
      end)

      scope = %{@scope | retention_class: :notification_content}
      {:ok, stored} = encrypt("body", scope)
      assert {:ok, _} = decrypt(stored, scope)
    end

    test "TN-65: a ciphertext does not decrypt in another tenant, environment, subject, class, table or column" do
      with_key()
      {:ok, stored} = encrypt("ayse@example.com")

      for scope <- [
            %{@scope | tenant_id: <<3::128>>},
            %{@scope | environment: :test},
            %{@scope | subject_id: <<4::128>>},
            %{@scope | retention_class: :preference},
            %{@scope | table: "deliveries"},
            %{@scope | column: "name_ct"},
            Map.put(%{@scope | subject_id: nil}, :key_id, <<5::128>>)
          ] do
        assert {:error, %Relay.Error{code: :decryption_failed}} = decrypt(stored, scope)
      end
    end

    property "TN-33: any change to the stored form is detected" do
      with_key()
      {:ok, stored} = encrypt("ayse@example.com")

      check all position <- integer(1..(byte_size(stored) - 1)), flip <- integer(1..255) do
        <<head::binary-size(^position), byte, tail::binary>> = stored
        tampered = <<head::binary, Bitwise.bxor(byte, flip), tail::binary>>
        assert {:error, %Relay.Error{code: :decryption_failed}} = decrypt(tampered)
      end
    end

    test "OP-17: a destroyed data key makes the field unreadable" do
      with_key()
      {:ok, stored} = encrypt("ayse@example.com")

      shredded = Relay.Error.new(:data_key_destroyed, "data key destroyed")
      stub(KeyProviderMock, :data_key, fn _ -> {:error, shredded} end)

      assert decrypt(stored) == {:error, shredded}
      assert encrypt("new value") == {:error, shredded}
    end

    test "TN-35: malformed input, keys and scopes are refused" do
      with_key(:binary.copy(<<1>>, 16))
      assert {:error, %Relay.Error{code: :invalid_data_key}} = encrypt("x")

      with_key()
      assert {:error, %Relay.Error{code: :invalid_ciphertext}} = decrypt(<<2, 0::size(28 * 8)>>)
      assert {:error, %Relay.Error{code: :invalid_ciphertext}} = decrypt(<<1, 0::size(27 * 8)>>)
      assert {:error, %Relay.Error{code: :invalid_plaintext}} = encrypt(:not_binary)

      for scope <- [
            %{@scope | tenant_id: "short"},
            %{@scope | environment: :staging},
            %{@scope | retention_class: :unknown},
            %{@scope | subject_id: nil},
            %{@scope | column: "external_id"},
            %{@scope | table: "Recipients"},
            Map.delete(@scope, :subject_id),
            Map.delete(@scope, :column)
          ] do
        assert {:error, %Relay.Error{code: :invalid_scope}} = encrypt("x", scope)
      end
    end

    test "T-58: plaintext is returned redacted and the key never shows" do
      with_key()
      {:ok, stored} = encrypt(Redacted.wrap("ayse@example.com"))
      {:ok, redacted} = decrypt(stored)

      refute inspect(redacted) =~ "ayse"
      refute stored =~ "ayse"
    end
  end
end
