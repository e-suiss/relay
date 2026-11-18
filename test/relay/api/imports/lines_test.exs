defmodule Relay.Api.Imports.LinesTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Imports.Lines

  describe "OP-96 lines" do
    test "OP-96: lines are numbered, blank lines skipped and broken lines put in the invalid bucket" do
      content = ~s({"a":1}\n\n[1]\n{bad\r\n) <> <<0xFF>> <> "\n"

      assert [
               {1, {:ok, %{"a" => 1}}},
               {3, {:invalid, "not_an_object"}},
               {4, {:invalid, "invalid_json"}},
               {5, {:invalid, "invalid_utf8"}}
             ] = Lines.split(content)

      assert Lines.count(content) == 4
    end

    test "OP-55 (7): encoding damage is found and clean Turkish text is not" do
      assert Lines.damaged?("Ã§ok gÃ¼zel")
      assert Lines.damaged?("Ä±ÅŸÄ±k")
      assert Lines.damaged?("bozuk � harf")
      assert Lines.damaged?("kontrol " <> <<0xC2, 0x85>>)
      refute Lines.damaged?("çok güzel ışık İstanbul")
      assert {:invalid, "encoding_damaged"} = Lines.decode(~s({"name":"Ã§ok"}))
    end

    test "OP-55 (7): phone numbers are normalised to E.164 without guessing" do
      assert {:ok, "+905321234567"} = Lines.phone("0532 123 45 67", "TR")
      assert {:ok, "+905321234567"} = Lines.phone("5321234567", "TR")
      assert {:ok, "+905321234567"} = Lines.phone("+90 (532) 123-4567", nil)
      assert {:ok, "+49301234567"} = Lines.phone("0049 30 1234567", nil)
      assert :error = Lines.phone("030 1234567", "DE")
      assert :error = Lines.phone("12", nil)
    end

    test "OP-55 (7): language tags are normalised to BCP 47" do
      assert {:ok, "tr-TR"} = Lines.locale("tr_TR")
      assert {:ok, "en-US"} = Lines.locale("EN-us")
      assert :error = Lines.locale("not a tag")
    end

    test "OP-55 (3): a refusal anywhere wins and an unknown never becomes a consent" do
      assert :refused = Lines.fold_consent([{1, "granted"}, {2, "refused"}])
      assert {:granted, 3} = Lines.fold_consent([{1, "granted"}, {3, "granted"}])
      assert :unknown = Lines.fold_consent([{1, "unknown"}])
      assert {:granted, 2} = Lines.fold_consent([{1, "unknown"}, {2, "granted"}])
    end

    test "OP-55 (4): dead tokens go first and the newest line of a token and platform stays" do
      lines = [
        {1, %{"token" => "a", "platform" => "fcm", "last_seen_at" => "2026-01-01T00:00:00Z"}},
        {2, %{"token" => "a", "platform" => "fcm", "last_seen_at" => "2026-06-01T00:00:00Z"}},
        {3, %{"token" => "a", "platform" => "fcm"}},
        {4, %{"token" => "a", "platform" => "apns"}},
        {5, %{"token" => "b", "platform" => "fcm", "state" => "dead"}}
      ]

      {kept, dead, older} = Lines.select_devices(lines)
      assert Enum.map(kept, &elem(&1, 0)) == [2, 4]
      assert dead == [5]
      assert older == [1, 3]
    end

    test "OP-55 (5): the same address under two external ids is a conflict, the same id is not" do
      entries = [
        {1, "u-1", "a@example.com"},
        {2, "u-2", "a@example.com"},
        {3, "u-3", "b@example.com"},
        {4, "u-3", "b@example.com"},
        {5, "u-4", nil}
      ]

      assert Lines.conflicts(entries) == [[1, 2]]
    end
  end
end
