defmodule Relay.EmailTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Email
  alias Relay.Redacted

  defp normalized(address) do
    {:ok, redacted} = Email.new(address)
    Redacted.expose(redacted)
  end

  defp local_part do
    gen all parts <-
              list_of(
                string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?+, ?_, ?-]]),
                  min_length: 1,
                  max_length: 10
                ),
                min_length: 1,
                max_length: 3
              ) do
      Enum.join(parts, ".")
    end
  end

  defp domain do
    gen all labels <-
              list_of(
                string(Enum.concat([?a..?z, ?A..?Z, ?0..?9]), min_length: 1, max_length: 12),
                min_length: 2,
                max_length: 4
              ) do
      Enum.join(labels, ".")
    end
  end

  describe "OP-1 normalized e-mail" do
    test "OP-1: surrounding space is trimmed and the domain is lowercased" do
      assert normalized("  Ayse.Yilmaz@Example.COM\n") == "Ayse.Yilmaz@example.com"
    end

    test "OP-1: text is normalized to Unicode NFC" do
      assert normalized("e\u0301mile@exa\u0301mple.com") == "\u00e9mile@ex\u00e1mple.com"
    end

    test "OP-1: internationalized addresses are accepted" do
      assert normalized("ŞEBNEM@Örnek.COM.tr") == "ŞEBNEM@örnek.com.tr"
    end

    property "OP-1: normalization is idempotent and ignores domain case" do
      check all local <- local_part(), domain <- domain() do
        address = local <> "@" <> domain
        once = normalized(address)

        assert normalized(once) == once
        assert normalized(local <> "@" <> String.upcase(domain)) == once
        assert once == local <> "@" <> String.downcase(domain)
      end
    end

    test "OP-1: malformed addresses are refused" do
      long_local = String.duplicate("a", 65) <> "@example.com"
      long_address = "a@" <> String.duplicate("abcdefghi.", 25) <> "com"

      for address <- [
            "",
            "plain",
            "a@b@example.com",
            "\"quoted\"@example.com",
            ".a@example.com",
            "a.@example.com",
            "a..b@example.com",
            "a b@example.com",
            "a@localhost",
            "a@-example.com",
            "a@example-.com",
            "a@example..com",
            "a@[192.0.2.1]",
            "a@exa_mple.com",
            "a(b)@example.com",
            long_local,
            long_address,
            <<0xFF, ?@, ?a, ?., ?b>>,
            nil
          ] do
        assert {:error, %Relay.Error{code: :invalid_email}} = Email.new(address)
      end
    end

    test "T-58: the address is redacted and errors never carry it" do
      assert {:ok, redacted} = Email.new(Redacted.wrap("secret.person@example.com"))
      refute inspect(redacted) =~ "secret.person"
      assert {:error, error} = Email.new("secret.person@@example.com")
      refute inspect(error) =~ "secret.person"
    end
  end
end
