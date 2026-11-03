defmodule Relay.Templates.SanitizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Direction
  alias Relay.Templates.Finding
  alias Relay.Templates.Sanitizer

  describe "INV-1 change log" do
    test "valid UTF-8 passes unchanged without a change" do
      assert Sanitizer.utf8("Merhaba dünya 😀", "body") == {"Merhaba dünya 😀", []}
    end

    test "invalid bytes are removed and counted" do
      assert {"ab", [%{rule: :invalid_utf8, action: :removed, count: 3, field: "body"}]} =
               Sanitizer.utf8(<<"a", 0xC3, 0xFF, 0xED, "b">>, "body")
    end

    test "an encoded surrogate is invalid UTF-8" do
      assert {"ab", [%{count: 3}]} = Sanitizer.utf8(<<"a", 0xED, 0xA0, 0x80, "b">>)
    end

    test "drop records the removed code points" do
      assert {"ac", [%{rule: :test, count: 2, detail: %{codepoints: [?b]}}]} =
               Sanitizer.drop("abbc", :test, nil, &(&1 == ?b))
    end

    test "pipe concatenates changes in order and with_field fills missing fields" do
      steps = [&Sanitizer.utf8/1, &Sanitizer.drop(&1, :x, "kept", fn c -> c == ?x end)]
      {value, changes} = Sanitizer.pipe(<<"x", 0xFF>>, steps)

      assert value == ""

      assert [%{rule: :invalid_utf8, field: "title"}, %{rule: :x, field: "kept"}] =
               Sanitizer.with_field(changes, "title")
    end

    property "the result is always valid UTF-8 and cleaning twice changes nothing" do
      check all bytes <- binary(max_length: 200) do
        {clean, changes} = Sanitizer.utf8(bytes)

        assert String.valid?(clean)
        assert Sanitizer.utf8(clean) == {clean, []}
        assert (changes == []) == String.valid?(bytes)
        assert byte_size(clean) + Enum.sum(Enum.map(changes, & &1.count)) == byte_size(bytes)
      end
    end
  end

  describe "TP-32 findings" do
    test "a hard finding blocks, warnings do not" do
      warning = Finding.new(:x, :warning, channel: :sms)
      hard = Finding.new(:y, :hard, locale: "tr", pointer: "/body", detail: %{n: 1})

      refute Finding.blocking?([warning])
      assert Finding.blocking?([warning, hard])
      assert Finding.split([warning, hard]) == {[hard], [warning]}
      assert %Finding{channel: nil, locale: "tr", pointer: "/body", detail: %{n: 1}} = hard
    end
  end

  describe "TP-29 direction" do
    test "language and script decide the direction" do
      assert Direction.of("ar") == :rtl
      assert Direction.of("he-IL") == :rtl
      assert Direction.of("fa_IR") == :rtl
      assert Direction.of("az-Arab") == :rtl
      assert Direction.of("tr-TR") == :ltr
      assert Direction.of("ku-Latn") == :ltr
      assert Direction.of(nil) == :ltr
      assert Direction.attribute("ur") == "rtl"
    end
  end
end
