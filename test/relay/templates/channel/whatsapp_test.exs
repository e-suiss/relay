defmodule Relay.Templates.Channel.WhatsappTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Channel.Whatsapp

  describe "TP-23 parameter cleaner" do
    test "line breaks and tabs become a space and every change is recorded" do
      assert {"Sipariş 1234 hazır", [%{rule: :line_break, action: :replaced, count: 2}]} =
               Whatsapp.clean("Sipariş\r\n1234\thazır", :body)
    end

    test "four or more spaces become three" do
      assert {"a   b   c", [%{rule: :space_run, count: 2}]} =
               Whatsapp.clean("a    b       c", :body)

      assert Whatsapp.clean("a   b", :body) == {"a   b", []}
    end

    test "values over the component limit are cut at a grapheme boundary" do
      value = String.duplicate("ğ", 59) <> "👨\u200D👩\u200D👧" <> "x"

      assert {cut, [%{rule: :truncated, action: :truncated, count: 1, detail: detail}]} =
               Whatsapp.clean(value, :header, "header/1")

      assert cut == String.duplicate("ğ", 59) <> "👨\u200D👩\u200D👧"
      assert detail == %{graphemes: 61, limit: 60}
    end

    test "component limits" do
      assert Enum.map([:body, :header, :footer, :button], &Whatsapp.limit/1) == [1024, 60, 60, 25]
    end

    test "clean_all names each parameter by component and index" do
      {values, changes} =
        Whatsapp.clean_all([{:body, "a\nb"}, {:body, "ok"}, {:body, "c\td"}, {:button, "x"}])

      assert values == ["a b", "ok", "c d", "x"]
      assert Enum.map(changes, & &1.field) == ["body/1", "body/3"]
    end
  end

  describe "TP-23 properties" do
    property "cleaned values are free of breaks and long space runs, fit and stay stable" do
      check all value <- string(:printable, max_length: 120),
                component <- member_of([:body, :header, :footer, :button]) do
        {clean, _changes} = Whatsapp.clean(value, component)

        refute clean =~ ~r/[\r\n\t]/
        refute clean =~ "    "
        assert String.length(clean) <= Whatsapp.limit(component)
        assert Whatsapp.clean(clean, component) == {clean, []}
      end
    end
  end
end
