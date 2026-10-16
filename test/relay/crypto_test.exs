defmodule Relay.CryptoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Crypto
  alias Relay.Redacted

  describe "TN-35 primitives" do
    property "TN-35: constant-time comparison agrees with equality" do
      check all a <- binary(), b <- one_of([constant(a), binary(length: byte_size(a)), binary()]) do
        assert Crypto.secure_compare(a, b) == (a == b)
      end
    end

    test "TN-35: binaries of different sizes are unequal" do
      refute Crypto.secure_compare("abc", "abcd")
      refute Crypto.secure_compare("", "a")
      assert Crypto.secure_compare("", "")
    end

    test "TN-35: HMAC-SHA256 matches RFC 4231 test case 2" do
      assert Crypto.hmac_sha256(Redacted.wrap("Jefe"), "what do ya want for nothing?") ==
               Base.decode16!("5BDCC146BF60754E6A042426089575C75A003F089D2739839DEC58B964EC3843")
    end

    test "TN-35: AES-256-GCM matches the GCM specification test case 16" do
      key = Base.decode16!("FEFFE9928665731C6D6A8F9467308308FEFFE9928665731C6D6A8F9467308308")
      iv = Base.decode16!("CAFEBABEFACEDBADDECAF888")

      plaintext =
        Base.decode16!(
          "D9313225F88406E5A55909C5AFF5269A86A7A9531534F7DA2E4C303D8A318A721C3C0C95956809532FCF0E2449A6B525B16AEDF5AA0DE657BA637B39"
        )

      aad = Base.decode16!("FEEDFACEDEADBEEFFEEDFACEDEADBEEFABADDAD2")

      ciphertext =
        Base.decode16!(
          "522DC1F099567D07F47F37A32A84427D643A8CDCBFE5C0C97598A2BD2555D1AA8CB08E48590DBB3DA7B08B1056828838C5F61E6393BA7A0ABCC9F662"
        )

      tag = Base.decode16!("76FC6ECE0F4E1768CDDF8853BB2D551B")

      assert Crypto.aes_256_gcm_encrypt(Redacted.wrap(key), iv, plaintext, aad) ==
               {ciphertext, tag}

      assert Crypto.aes_256_gcm_decrypt(key, iv, ciphertext, aad, tag) == {:ok, plaintext}
      assert Crypto.aes_256_gcm_decrypt(key, iv, ciphertext, "other", tag) == :error
    end
  end
end
