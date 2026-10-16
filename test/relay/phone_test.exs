defmodule Relay.PhoneTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Phone
  alias Relay.Redacted

  defp digits(min, max), do: string(?0..?9, min_length: min, max_length: max)

  describe "OP-1 E.164" do
    test "OP-1: a Turkish mobile number in E.164 form is accepted and redacted" do
      assert {:ok, number} = Phone.new("+905321234567")
      assert Redacted.expose(number) == "+905321234567"
      refute inspect(number) =~ "5321234567"
    end

    test "OP-1: a Turkish number written with its trunk zero is refused" do
      assert {:error, %Relay.Error{code: :invalid_phone}} = Phone.new("+9005321234567")
    end

    property "OP-1: every +900 number is refused" do
      check all rest <- digits(0, 12) do
        assert {:error, %Relay.Error{code: :invalid_phone}} = Phone.new("+900" <> rest)
      end
    end

    property "OP-1: well-formed E.164 numbers outside +900 are accepted unchanged" do
      check all first <- integer(1..9),
                rest <- digits(1, 14),
                number = "+#{first}#{rest}",
                not String.starts_with?(number, "+900") do
        assert {:ok, redacted} = Phone.new(number)
        assert Redacted.expose(redacted) == number
      end
    end

    test "OP-1: non-canonical forms are refused" do
      for number <- [
            "905321234567",
            "+0123456789",
            "+1",
            "+1234567890123456",
            "+90 532 123 45 67",
            "+90-532-1234567",
            "+90532123456a",
            "",
            nil,
            905_321_234_567
          ] do
        assert {:error, %Relay.Error{code: :invalid_phone}} = Phone.new(number)
      end
    end

    test "T-58: a redacted number is accepted and errors never carry the number" do
      assert {:ok, _} = Phone.new(Redacted.wrap("+4915123456789"))
      assert {:error, error} = Phone.new("+9005321234567")
      refute inspect(error) =~ "5321234567"
    end
  end
end
