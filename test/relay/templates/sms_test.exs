defmodule Relay.Templates.SmsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Finding
  alias Relay.Templates.Sms
  alias Relay.Templates.Sms.Content
  alias Relay.Templates.Sms.Encoding
  alias Relay.Templates.Sms.Transliteration

  @zero_width [0x200B, 0x200C, 0x200D, 0xFEFF]

  defp forbidden?(c) when c in [?\n, ?\r], do: false
  defp forbidden?(c), do: c < 0x20 or c in 0x7F..0x9F or c in 0x202A..0x202E or c in @zero_width

  describe "TP-18 TP-53 plan" do
    test "Turkish text is planned as GSM7_TR and measured as UCS2 on an unverified provider" do
      plan = Sms.plan("Şifreniz değişti. Sorunuz için bizi arayın.")

      assert plan.encoding == :gsm7_tr
      assert plan.name == "GSM7_TR"
      assert plan.segments == 1
      assert plan.characters == 43
      assert plan.units == 48
      assert plan.unverified == %{encoding: :ucs2, name: "UCS2", segments: 1, units: 43}
      assert plan.changes == []
    end

    test "on GSM7 the unverified provider sees the same plan" do
      plan = Sms.plan(String.duplicate("a", 161))

      assert {plan.encoding, plan.segments} == {:gsm7, 2}
      assert plan.unverified == %{encoding: :gsm7, name: "GSM7", segments: 2, units: 161}
    end

    test "the ucs2 policy never uses the single shift table" do
      plan = Sms.plan("Kodunuz: 1234 ş", policy: :ucs2)
      assert {plan.encoding, plan.segments} == {:ucs2, 1}
    end

    test "the transliterate policy turns Turkish letters into GSM letters and records it" do
      plan = Sms.plan("Şifreniz değişti, ılık çay", policy: :transliterate)

      assert plan.text == "Sifreniz degisti, ilik cay"
      assert plan.encoding == :gsm7
      assert [%{rule: :transliterated, action: :replaced, count: 6, field: "body"}] = plan.changes
    end

    test "CH-49: a security body is always transliterated, the legal text never" do
      opts = [message_class: "security", legal: "İptal: RET yazın"]
      plan = Sms.plan("Doğrulama kodunuz: 482913", opts)

      assert plan.body == "Dogrulama kodunuz: 482913"
      assert plan.legal == "İptal: RET yazın"
      assert plan.text == "Dogrulama kodunuz: 482913\nİptal: RET yazın"
      assert plan.encoding == :gsm7_tr
    end

    test "CH-49: other classes keep Turkish letters unless the template flag is on" do
      plan = Sms.plan("Siparişiniz yolda", message_class: "transactional")
      assert plan.text == "Siparişiniz yolda"
    end

    test "TP-19: the legal text is reserved before the body budget" do
      legal = "MERSIS 0123 RET 4609"
      plan = Sms.plan(String.duplicate("a", 100), legal: legal)

      assert plan.legal_units == 21
      assert plan.units == 121
      assert plan.body_capacity == 160 - 21
    end

    test "reserved prefix units push the message into a second segment" do
      assert Sms.plan(String.duplicate("a", 158), reserved: 3).segments == 2
      assert Sms.plan(String.duplicate("a", 158), reserved: 2).segments == 1
    end

    test "CH-48: characters that force UCS-2 are listed and can be normalised" do
      plan = Sms.plan("“Fırsat” bitti… 50₺")

      assert plan.encoding == :ucs2
      assert [%{codepoint: 0x201C, normalizable: true} | _rest] = plan.ucs2_characters
      assert Enum.map(plan.ucs2_characters, & &1.codepoint) == [0x201C, 0x201D, 0x2026, 0x20BA]

      normalized = Sms.plan("“Fırsat” bitti… 50₺", normalize: true)
      assert normalized.text == "\"Fırsat\" bitti... 50TL"
      assert normalized.encoding == :gsm7_tr
      assert [%{rule: :normalized, count: 4}] = normalized.changes
    end

    test "an emoji forces UCS-2 and is counted" do
      plan = Sms.plan("Kargonuz yolda 🚚")

      assert plan.encoding == :ucs2
      assert plan.emoji == 1
      assert plan.units == 17
      assert [%{codepoint: 0x1F69A, normalizable: false}] = plan.ucs2_characters
    end

    test "TP-19: control, zero-width and direction characters are removed and recorded" do
      plan = Sms.plan("Ko\u0007d\u200B: \u202E1234\n")

      assert plan.text == "Kod: 1234\n"

      assert Enum.map(plan.changes, & &1.rule) == [
               :control_character,
               :zero_width,
               :direction_control
             ]
    end

    test "invalid UTF-8 is removed and recorded" do
      plan = Sms.plan(<<"Kod", 0xFF, ": 1">>)

      assert plan.text == "Kod: 1"
      assert [%{rule: :invalid_utf8, count: 1, field: "body"}] = plan.changes
    end
  end

  describe "TP-32 findings" do
    test "UCS-2 characters, emoji and too many segments are warnings" do
      plan = Sms.plan(String.duplicate("😀", 40))
      findings = Sms.findings(plan, locale: "tr", max_segments: 1)

      expected = [:sms_ucs2_characters, :sms_emoji_value, :sms_segments]
      assert Enum.map(findings, & &1.check) == expected
      assert Enum.all?(findings, &(&1.level == :warning and &1.channel == :sms))
      refute Finding.blocking?(findings)
    end

    test "a clean plan has no findings" do
      assert Sms.findings(Sms.plan("Kod: 1234"), max_segments: 1) == []
    end
  end

  describe "TP-19 content" do
    test "emoji in template text is a hard finding" do
      assert [%Finding{check: :sms_emoji, level: :hard, detail: %{count: 2}}] =
               Content.template_findings("Merhaba 👋 {{ name }} 🎉", locale: "tr")

      assert Content.template_findings("Merhaba {{ name }}") == []
    end

    test "emoji in a variable value are stripped or accepted by policy, never silently" do
      assert {"Ayşe ", [%{rule: :emoji, action: :removed, count: 1}]} =
               Content.clean_value("Ayşe 🌸", :strip, "name")

      assert {"Ayşe 🌸", [%{rule: :emoji, action: :flagged, count: 1}]} =
               Content.clean_value("Ayşe 🌸", :accept, "name")
    end

    test "a zero-width joiner sequence is removed as emoji graphemes after sanitising" do
      {value, changes} = Content.clean_value("a👨\u200D👩\u200D👧b", :strip)

      assert value == "ab"
      assert Enum.map(changes, & &1.rule) == [:zero_width, :emoji]
    end

    property "sanitising removes every forbidden code point and is idempotent" do
      check all text <- string(:utf8, max_length: 80) do
        {clean, _changes} = Content.sanitize(text)

        refute Enum.any?(String.to_charlist(clean), &forbidden?/1)

        assert Content.sanitize(clean) == {clean, []}
      end
    end
  end

  describe "CH-49 transliteration" do
    test "applies? follows the message type" do
      assert Transliteration.applies?("security", :body, false)
      refute Transliteration.applies?("security", :legal, true)
      refute Transliteration.applies?("marketing", :body, false)
      assert Transliteration.applies?("marketing", :body, true)
    end

    test "letters the default alphabet carries stay" do
      assert {"Çok güzel ögün", [%{rule: :transliterated, action: :replaced, count: 1}]} =
               Transliteration.transliterate("Çok güzel öğün")
    end

    test "İ and ı become I and i" do
      assert {"ISTANBUL istanbul", _changes} = Transliteration.transliterate("İSTANBUL ıstanbul")
    end

    property "transliterated Latin text is carried by GSM7 or keeps only non-Latin characters" do
      check all text <- string(Enum.concat([?a..?z, ~c"çğıöşüÇĞİÖŞÜâîû "]), max_length: 120) do
        {result, _changes} = Transliteration.transliterate(text)
        assert Encoding.fits?(result, :gsm7)
        assert String.length(result) == String.length(text)
      end
    end
  end
end
