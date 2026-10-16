defmodule Relay.IdTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Relay.Id
  alias Relay.Id.External

  setup :verify_on_exit!

  defp rand_bytes, do: binary(length: 10)
  defp unix_ms, do: integer(0..(Integer.pow(2, 48) - 1))

  describe "OP-1 T-60 UUIDv7 layout" do
    test "OP-1: the RFC 9562 appendix A.6 example is reproduced" do
      id = Id.build(0x017F22E279B0, <<0xCC3::12, 0x18C4DC0C0C07398F::62, 0::6>>)

      assert Id.to_string(id) == "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
      assert Id.timestamp_ms(id) == 0x017F22E279B0
    end

    property "T-60: every identifier has version 7, the RFC variant and its timestamp" do
      check all ms <- unix_ms(), bytes <- rand_bytes() do
        id = Id.build(ms, bytes)

        assert <<^ms::48, 7::4, _::12, 2::2, _::62>> = id
        assert Id.valid?(id)
        assert Id.timestamp_ms(id) == ms
      end
    end

    property "OP-1: identifiers from later milliseconds sort after earlier ones" do
      check all a <- unix_ms(), b <- unix_ms(), a != b, ra <- rand_bytes(), rb <- rand_bytes() do
        [early, late] = Enum.sort([a, b])
        assert Id.build(early, ra) < Id.build(late, rb)
        assert Id.to_string(Id.build(early, ra)) < Id.to_string(Id.build(late, rb))
      end
    end

    property "OP-1: the text form round-trips and ignores letter case" do
      check all ms <- unix_ms(), bytes <- rand_bytes() do
        id = Id.build(ms, bytes)
        text = Id.to_string(id)

        assert Id.parse(text) == {:ok, id}
        assert Id.parse(String.upcase(text)) == {:ok, id}
      end
    end

    test "OP-1: other UUID versions and malformed text are refused" do
      for text <- [
            "017f22e2-79b0-4cc3-98c4-dc0c0c07398f",
            "017f22e2-79b0-7cc3-c8c4-dc0c0c07398f",
            "017f22e279b07cc398c4dc0c0c07398f",
            "017f22e2-79b0-7cc3-98c4-dc0c0c07398g",
            "",
            nil
          ] do
        assert {:error, %Relay.Error{code: :invalid_id}} = Id.parse(text)
      end

      refute Id.valid?(<<0::128>>)
    end
  end

  describe "T-57 ports" do
    setup do
      previous = {Application.fetch_env!(:relay, :clock), Application.fetch_env!(:relay, :random)}
      Application.put_env(:relay, :clock, Relay.ClockMock)
      Application.put_env(:relay, :random, Relay.RandomMock)

      on_exit(fn ->
        {clock, random} = previous
        Application.put_env(:relay, :clock, clock)
        Application.put_env(:relay, :random, random)
      end)
    end

    test "T-57: generation takes time from the clock and randomness from the random port" do
      expect(Relay.ClockMock, :utc_now, fn -> ~U[2022-02-22 19:22:22.000000Z] end)

      expect(Relay.RandomMock, :bytes, fn 10 ->
        <<0xCC3::12, 0x18C4DC0C0C07398F::62, 0::6>>
      end)

      assert Id.to_string(Id.generate()) == "017f22e2-79b0-7cc3-98c4-dc0c0c07398f"
    end
  end

  describe "API-9 T-58 external identifiers" do
    @example Id.build(0x017F22E279B0, <<0xCC3::12, 0x18C4DC0C0C07398F::62, 0::6>>)

    test "API-9: the prefix, an underscore and 26 lowercase Crockford base32 characters" do
      assert Id.encode(:notification, @example) == "ntf_01fwhe4ydgfk1shh6w1g60eecf"
      assert Id.encode(:subtenant, @example) == "stn_01fwhe4ydgfk1shh6w1g60eecf"
      assert Id.encode(:waitpoint, @example) == "wp_01fwhe4ydgfk1shh6w1g60eecf"
    end

    property "API-9: external identifiers round-trip and keep time order" do
      check all a <- unix_ms(), b <- unix_ms(), a != b, ra <- rand_bytes(), rb <- rand_bytes() do
        [early, late] = Enum.sort([a, b])
        first = Id.build(early, ra)
        second = Id.build(late, rb)
        text = Id.encode(:delivery, first)

        assert text =~ ~r/\Adlv_[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}\z/
        assert Id.decode(text, :delivery) == {:ok, first}
        assert text < Id.encode(:delivery, second)
      end
    end

    test "T-58: every prefix names exactly one kind" do
      prefixes = Enum.map(Id.prefixes(), &elem(&1, 1))
      assert length(prefixes) == length(Enum.uniq(prefixes))
      assert Id.prefix(:subtenant) == "stn"
      assert Id.prefix(:subscriber) == "sub"
    end

    test "API-9: a wrong prefix, upper case or a non-canonical body is refused" do
      text = Id.encode(:notification, @example)
      body = String.trim_leading(text, "ntf_")

      for bad <- [
            "dlv_" <> body,
            String.upcase(text),
            "NTF_" <> body,
            "ntf_" <> String.upcase(body),
            "ntf_" <> String.replace(body, "1", "l"),
            "ntf_8" <> String.slice(body, 1..-1//1),
            "ntf_" <> String.slice(body, 0..24),
            "ntf" <> body,
            "xyz_" <> body,
            Id.to_string(@example),
            nil
          ] do
        assert {:error, %Relay.Error{code: :invalid_id}} = Id.decode(bad, :notification)
      end
    end

    test "API-9: a sub-tenant identifier never resolves as a subscriber and back" do
      assert {:error, _} = Id.decode(Id.encode(:subtenant, @example), :subscriber)
      assert {:error, _} = Id.decode(Id.encode(:subscriber, @example), :subtenant)
    end

    test "API-9: a recipient resolves from its kind-neutral and its typed prefixes" do
      kinds = [:recipient, :subscriber, :agent]

      for kind <- kinds do
        assert Id.decode_kind(Id.encode(kind, @example), kinds) == {:ok, kind, @example}
      end

      assert {:error, _} = Id.decode(Id.encode(:recipient, @example), :subscriber)
    end

    test "API-9: an identifier that is not UUIDv7 has no external form" do
      v4 = <<0x017F22E279B0::48, 4::4, 0::12, 2::2, 0::62>>

      body =
        for <<(c::5 <- <<0::2, v4::binary>>)>>,
          into: "",
          do: <<Enum.at(~c"0123456789abcdefghjkmnpqrstvwxyz", c)>>

      assert {:error, _} = Id.decode("ntf_" <> body, :notification)
    end

    test "API-9: the Ecto type validates the prefix of its field" do
      params = External.init(kinds: [:recipient, :subscriber, :agent])

      assert External.cast(Id.encode(:subscriber, @example), params) == {:ok, @example}
      assert {:error, _} = External.cast(Id.encode(:notification, @example), params)
      assert External.cast(42, params) == :error
      assert External.dump(@example, nil, params) == {:ok, @example}
      assert External.dump(<<0::128>>, nil, params) == :error
      assert External.load(@example, nil, params) == {:ok, @example}
      assert_raise ArgumentError, fn -> External.init(kind: :unknown) end
    end
  end
end
