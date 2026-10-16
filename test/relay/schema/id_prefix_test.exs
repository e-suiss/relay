defmodule Relay.Schema.IdPrefixTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.ExternalId

  @stage_one_tables ~w(tenants subtenants recipients notifications deliveries delivery_attempts
                       delivery_events webhook_receipts outbox_events audit_log audit_checkpoints
                       dataset_versions usage_records secret_refs legal_holds erasure_log)

  defp id, do: Relay.Id.build(1_760_000_000_000, :crypto.strong_rand_bytes(10))

  describe "API-9 T-58 prefixed identifiers" do
    test "API-9: every prefix resolves to exactly one table and prefixes are unique" do
      prefixes = ExternalId.prefixes()
      assert prefixes == Enum.uniq(prefixes)

      for prefix <- prefixes do
        assert {:ok, table} = ExternalId.table(prefix)
        assert is_binary(table)
      end
    end

    test "API-9: subscriber, agent and recipient prefixes all resolve to the recipients table" do
      for prefix <- ["sub", "agt", "rcp"],
          do: assert(ExternalId.table(prefix) == {:ok, "recipients"})
    end

    test "API-9: every stage one record table has a prefix" do
      tables =
        for prefix <- ExternalId.prefixes(), {:ok, table} = ExternalId.table(prefix), do: table

      for table <- @stage_one_tables, do: assert(table in tables, table)
    end

    test "API-72: an identifier is the prefix and 26 lowercase Crockford base32 characters" do
      text = ExternalId.encode("ntf", id())
      assert text =~ ~r/^ntf_[0-9abcdefghjkmnpqrstvwxyz]{26}$/
    end

    property "API-9: an identifier decodes only under its own prefix" do
      check all prefix <- member_of(ExternalId.prefixes()),
                other <- member_of(ExternalId.prefixes()) do
        uuid = id()
        text = ExternalId.encode(prefix, uuid)
        assert ExternalId.decode(text, [prefix]) == {:ok, uuid}

        if other != prefix,
          do: assert({:error, %Relay.Error{code: :invalid_id}} = ExternalId.decode(text, [other]))
      end
    end

    test "T-58: uppercase, unprefixed, unknown and malformed identifiers are refused" do
      text = ExternalId.encode("dlv", id())
      [_, body] = String.split(text, "_")

      for bad <- [
            String.upcase(text),
            body,
            "xyz_" <> body,
            "dlv_" <> String.slice(body, 1..-1//1),
            "dlv_" <> body <> "0",
            "dlv_u" <> String.slice(body, 1..-1//1),
            "dlv_8" <> String.slice(body, 1..-1//1)
          ] do
        assert {:error, %Relay.Error{code: :invalid_id}} = ExternalId.decode(bad, ["dlv"]), bad
      end
    end

    test "T-58: a UUID that is not version 7 is refused" do
      v4 = <<0::48, 4::4, 0::12, 2::2, 0::62>>

      body =
        for <<(v::5 <- <<0::2, v4::binary>>)>>,
          into: "",
          do: <<Enum.at(~c"0123456789abcdefghjkmnpqrstvwxyz", v)>>

      assert {:error, _} = ExternalId.decode("ten_" <> body, ["ten"])
    end
  end
end
