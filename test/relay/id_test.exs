defmodule Relay.IdTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Mox

  alias Relay.Id

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
end
