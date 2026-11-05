defmodule Relay.Templates.LintTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Lint.Accessibility
  alias Relay.Templates.Lint.LegalFooter
  alias Relay.Templates.Lint.Promotion
  alias Relay.Templates.Lint.Sensitive
  alias Relay.Templates.Lint.Terms

  @sensitive [
    %{"term" => "borc", "locale" => "tr", "category" => "finance"},
    %{"term" => "icra", "locale" => "tr", "category" => "finance"},
    %{"term" => "tahlil", "locale" => "tr", "category" => "health"},
    %{"term" => "din", "locale" => "tr", "category" => "special"},
    %{"term" => "iban", "locale" => nil, "category" => "finance"},
    %{"term" => "account number", "locale" => "en", "category" => "finance"},
    %{"term" => "pregnan", "locale" => "en", "category" => "health"}
  ]

  @promotional [
    %{"term" => "indirim kodu", "locale" => "tr", "category" => nil},
    %{"term" => "hemen satın al", "locale" => "tr", "category" => nil},
    %{"term" => "kampanyayı kaçırma", "locale" => "tr", "category" => nil},
    %{"term" => "shop now", "locale" => "en", "category" => nil}
  ]

  @brand_tr %{
    "legal_name" => "Örnek A.Ş.",
    "mersis" => "0123456789012345",
    "commercial_mark" => "Ticari ileti"
  }

  defp terms(matches), do: Enum.map(matches, & &1.term)

  defp variant(fields \\ %{}) do
    base = %{channel: :sms, locale: "tr", helpers: ["legal_footer"], opt_out: "RET 4609"}
    Map.merge(base, fields)
  end

  describe "TP-46 folding and matching" do
    test "Turkish folding handles dotted and dotless i and accents" do
      assert Terms.fold("İCRA Işık Borç", "tr") == "icra isik borc"
      assert Terms.fold("İCRA", "en") == "icra"
      assert Terms.fold("  a \n\t b ", nil) == "a b"
    end

    test "a stem matches suffixed forms at a word start only" do
      assert terms(Sensitive.matches(["Borcunuz 500 TL"], [], @sensitive, "tr")) == ["borc"]
      assert terms(Sensitive.matches(["Kalan BORÇ: 5 TL"], [], @sensitive, "tr-TR")) == ["borc"]
      assert Sensitive.matches(["Yazborcunuz"], [], @sensitive, "tr") == []
      assert terms(Sensitive.matches(["(icra) dosyası"], [], @sensitive, "tr")) == ["icra"]
    end

    test "entries apply to their locale only, nil applies everywhere" do
      assert Sensitive.matches(["See you at dinner"], [], @sensitive, "en") == []
      assert terms(Sensitive.matches(["Your IBAN changed"], [], @sensitive, "en")) == ["iban"]
      assert terms(Sensitive.matches(["Pregnancy test"], [], @sensitive, "en-GB")) == ["pregnan"]
    end

    test "variable names are split into words" do
      found = Sensitive.matches([], ["user.ibanNumber", "debt.account_number"], @sensitive, "en")
      assert terms(found) == ["iban", "account number"]
    end

    test "matches are reported once per entry" do
      found = Sensitive.matches(["tahlil", "Tahlil sonucu"], ["tahlil_id"], @sensitive, "tr")
      assert [%{term: "tahlil", category: "health", locale: "tr"}] = found
    end

    property "a term always matches itself after any non-letter prefix" do
      check all prefix <- string(~c" .,;:!?()-", max_length: 5),
                entry <- member_of(@sensitive) do
        locale = entry["locale"] || "en"
        assert entry["term"] in terms(Terms.scan([prefix <> entry["term"]], @sensitive, locale))
      end
    end
  end

  describe "TP-21 TP-46 sensitive gate" do
    test "a match without confirmation is a hard finding" do
      opts = [locale: "tr", channel: :push, sensitivity: :personal]

      assert [%{check: :sensitive_terms, level: :hard, channel: :push, detail: detail}] =
               Sensitive.check(["Tahlil sonucunuz hazır"], [], @sensitive, opts)

      assert terms(detail.terms) == ["tahlil"]
      assert Sensitive.check(["Tahlil"], [], @sensitive, opts ++ [confirmed: true]) == []
    end

    test "a missing sensitivity class is a hard finding" do
      assert [%{check: :sensitivity_missing, level: :hard}] =
               Sensitive.check(["Siparişiniz yolda"], [], @sensitive, locale: "tr")
    end
  end

  describe "TP-12 TP-54 promotion leak" do
    test "a call to action in a transactional template is a hard finding" do
      opts = [message_class: "transactional", locale: "tr", channel: :email]

      assert [%{check: :promotion, level: :hard, detail: %{terms: [%{term: "indirim kodu"}]}}] =
               Promotion.check(["Siparişiniz alındı. İNDİRİM KODU: YAZ20"], @promotional, opts)
    end

    test "a receipt line is not a call to action" do
      opts = [message_class: "operational", locale: "tr"]
      assert Promotion.check(["Kampanya indirimi: 20 TL"], @promotional, opts) == []
    end

    test "marketing templates are not checked" do
      opts = [message_class: "marketing", locale: "tr"]
      assert Promotion.check(["Hemen satın al!"], @promotional, opts) == []
    end

    test "phrases with Turkish letters fold before matching" do
      opts = [message_class: "transactional", locale: "tr"]
      assert [_finding] = Promotion.check(["Kampanyayi kacirma"], @promotional, opts)
    end
  end

  describe "TP-33 TP-55 legal footer" do
    test "a complete Turkish marketing variant passes" do
      opts = [message_class: "marketing", country: "TR"]
      assert LegalFooter.check([variant()], @brand_tr, opts) == []

      with_contact = @brand_tr |> Map.delete("mersis") |> Map.put("contact", "x")
      assert LegalFooter.check([variant()], with_contact, opts) == []
    end

    test "a missing helper and missing fields are hard findings" do
      opts = [message_class: "marketing", country: "tr"]
      brand = %{"legal_name" => " ", "contact" => ""}

      email = variant(%{channel: :email, helpers: [], opt_out: nil})

      assert [
               %{check: :legal_footer_missing, level: :hard, channel: :email},
               %{check: :legal_footer_fields, level: :hard, detail: detail}
             ] = LegalFooter.check([email], brand, opts)

      assert detail == %{
               missing: ["legal_name", "mersis_or_contact", "opt_out"],
               country: "TR"
             }
    end

    test "the US needs a postal address" do
      opts = [message_class: "marketing", country: "US"]

      assert [%{check: :legal_footer_fields, detail: %{missing: ["postal_address"]}}] =
               LegalFooter.check([variant()], %{}, opts)

      assert LegalFooter.check([variant()], %{"postal_address" => "1 Main St"}, opts) == []
    end

    test "only commercial templates are checked" do
      opts = [message_class: "transactional"]
      assert LegalFooter.check([variant(%{helpers: []})], %{}, opts) == []
    end

    test "CH-56: a commercial voice variant names its sender by the trade name in every country" do
      opts = [message_class: "marketing", country: "DE"]
      voice = variant(%{channel: :voice})

      assert [%{check: :voice_trade_name, level: :hard, channel: :voice}] =
               LegalFooter.check([voice], %{}, opts)

      assert LegalFooter.check([voice], %{"legal_name" => "Örnek A.Ş."}, opts) == []
      assert LegalFooter.check([voice], @brand_tr, message_class: "marketing", country: "TR") == []
    end
  end

  describe "TP-34 accessibility" do
    @good ~s(<html lang="tr"><body><img src="a.png" alt="Logo"><p style="color:#000;background-color:#fff">Merhaba</p></body></html>)

    test "a good e-mail has no warnings" do
      assert Accessibility.email(%{"html" => @good, "text" => "Merhaba"}, locale: "tr") == []
    end

    test "missing lang, missing alt, image-only, missing text and low contrast are warnings" do
      head = ~s(<html><head><style>p{}</style></head><body><img src="a.png">)
      div = ~s[<div style='color: #777; background: #888 url(x.png)'>&nbsp;</div>]
      html = head <> div <> "</body></html>"
      findings = Accessibility.email(%{"html" => html}, locale: "tr")

      assert Enum.map(findings, & &1.check) == [
               :a11y_lang,
               :a11y_img_alt,
               :a11y_image_only,
               :a11y_plain_text,
               :a11y_contrast
             ]

      assert Enum.all?(findings, &(&1.level == :warning))
      assert %{detail: %{count: 1, minimum: 4.5}} = List.last(findings)
    end

    test "an empty alt marks a decorative image" do
      html = ~s(<html lang="en"><body><img src="a.png" alt="">Hello</body></html>)
      assert Accessibility.email(%{"html" => html, "text" => "Hello"}) == []
    end

    test "contrast follows WCAG" do
      assert_in_delta Accessibility.contrast({0, 0, 0}, {255, 255, 255}), 21.0, 1.0e-9
      assert Accessibility.contrast({119, 119, 119}, {136, 136, 136}) < 1.3
      assert Accessibility.parse_color("#FFF") == {255, 255, 255}
      assert Accessibility.parse_color("#0a0B0c") == {10, 11, 12}
      assert Accessibility.parse_color("rgb(1, 2, 300)") == {1, 2, 255}
      assert Accessibility.parse_color("red") == nil
    end

    test "the meaning belongs in the first line" do
      opts = [locale: "tr", channel: :push, pointer: "/body"]

      assert [%{check: :a11y_first_line, level: :warning, pointer: "/body", channel: :push}] =
               Accessibility.first_line("Merhaba Ahmet,\nKodunuz 1234", opts)

      assert [_finding] = Accessibility.first_line("\nKodunuz 1234")
      assert [_finding] = Accessibility.first_line("Sayın müşterimiz,", locale: "tr")
      assert Accessibility.first_line("Kodunuz 1234. Merhaba", locale: "tr") == []
      long = "Hi Ahmet, your code is 1234 and it expires in ten minutes"
      assert Accessibility.first_line(long) == []
    end

    test "lock screen fields carry no sensitive term" do
      fields = %{"title" => "Borç hatırlatması", "body" => "Yeni bir bildiriminiz var"}

      assert [%{check: :a11y_lock_screen, level: :warning, pointer: "/title", channel: :push}] =
               Accessibility.lock_screen(fields, @sensitive, locale: "tr")
    end
  end
end
