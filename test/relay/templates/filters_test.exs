defmodule Relay.Templates.FiltersTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Filters

  defp render(source, data, opts \\ []) do
    channel = Keyword.get(opts, :channel, :sms)
    {:ok, template} = Engine.parse(source, allow_raw: Keyword.get(opts, :allow_raw, false))

    {:ok, context} =
      Context.new(channel,
        locale: Keyword.get(opts, :locale, "tr"),
        time_zone: Keyword.get(opts, :time_zone, "Europe/Istanbul"),
        data: data,
        part: Keyword.get(opts, :part)
      )

    {:ok, output} = Engine.render(template, context, channel)
    output
  end

  describe "TP-28 locale-aware case" do
    test "TP-28: Turkish and Azerbaijani use the dotted and dotless i" do
      data = %{"s" => "istanbul ılık", "u" => "IŞIK İZMİR", "c" => "ılgın"}

      assert render("{{ s | upcase }}", data) == "İSTANBUL ILIK"
      assert render("{{ u | downcase }}", data) == "ışık izmir"
      assert render("{{ c | capitalize }}", data) == "Ilgın"
      assert render("{{ s | capitalize }}", data) == "İstanbul ılık"
      assert render("{{ s | upcase }}", data, locale: "az") == "İSTANBUL ILIK"
    end

    test "TP-28: other locales use the default mapping" do
      assert render("{{ s | upcase }}", %{"s" => "istanbul"}, locale: "en") == "ISTANBUL"
      assert render("{{ s | capitalize }}", %{"s" => "istanbul"}, locale: "de") == "Istanbul"
    end
  end

  describe "TP-45 text and array filters" do
    test "TP-45: truncate counts graphemes and includes the ellipsis" do
      data = %{"s" => "Merhaba dünya", "e" => "👍🏽👍🏽👍🏽"}

      assert render("{{ s | truncate: 8 }}", data) == "Merha..."
      assert render("{{ s | truncate: 20 }}", data) == "Merhaba dünya"
      assert render("{{ e | truncate: 2, \"\" }}", data) == "👍🏽👍🏽"
      assert render("{{ s | truncate: 8, \"…\" }}", data) == "Merhaba…"
    end

    test "TP-45: the remaining text filters" do
      data = %{"s" => "  Ali  ", "q" => "a b&c", "n" => nil, "e" => ""}

      assert render("[{{ s | strip }}][{{ s | lstrip }}][{{ s | rstrip }}]", data) ==
               "[Ali][Ali  ][  Ali]"

      assert render("{{ q | replace: \"b\", \"x\" }}", data) == "a x&c"
      assert render("{{ q | prepend: \"<\" | append: \">\" }}", data) == "<a b&c>"
      assert render("{{ q | url_encode }}", data) == "a+b%26c"
      assert render("{{ n | default: \"Değerli müşterimiz\" }}", data) == "Değerli müşterimiz"
      assert render("{{ e | default: \"-\" }}", data) == "-"
      assert render("{{ q | default: \"-\" }}", data) == "a b&c"
    end

    test "TP-45: size, first, last and join" do
      data = %{"items" => ["a", "b", "c"], "s" => "Çağrı"}

      assert render("{{ items | size }} {{ s | size }}", data) == "3 5"
      assert render("{{ items | first }}{{ items | last }}", data) == "ac"
      assert render("{{ items | join: \", \" }}|{{ items | join }}", data) == "a, b, c|a b c"
      assert render("{{ s | first }}{{ s | last }}", data) == "Çı"
    end

    test "TP-19: sms_safe removes invisible characters and plain-texts punctuation" do
      data = %{"s" => "“Merhaba”\u200B – dünya…\u202E\u00A0son"}
      assert render("{{ s | sms_safe }}", data) == "\"Merhaba\" - dünya... son"
    end
  end

  describe "TP-27 CLDR formatting" do
    test "TP-27: numbers and percentages in the recipient's locale" do
      data = %{"n" => 1_234_567.891, "p" => 0.25, "d" => "1234.5"}

      assert render("{{ n | number }}", data) == "1.234.567,891"
      assert render("{{ n | number }}", data, locale: "en") == "1,234,567.891"
      assert render("{{ d | number: 2 }}", data) == "1.234,50"
      assert render("{{ p | percent }}", data) == "%25"
      assert render("{{ p | percent }}", data, locale: "en") == "25%"
    end

    test "TP-16: currency formats a structured amount" do
      data = %{
        "try" => %{"amount" => "1249.90", "currency" => "TRY"},
        "usd" => %{"amount" => "1249.90", "currency" => "USD"}
      }

      assert render("{{ try | currency }}", data) == "₺1.249,90"
      assert render("{{ usd | currency }}", data, locale: "en") == "$1,249.90"
    end

    test "TP-16: currency refuses anything but {amount: string, currency}" do
      {:ok, template} = Engine.parse("{{ total | currency }}")

      for total <- [12.5, "12.50", %{"amount" => 12.5, "currency" => "TRY"}] do
        {:ok, context} =
          Context.new(:sms, locale: "tr", time_zone: "UTC", data: %{"total" => total})

        assert {:error, {:schema_violation, _}} = Engine.render(template, context, :sms)
      end
    end

    test "TP-27: date and time in the recipient's time zone" do
      data = %{"at" => "2026-01-15T09:30:00Z", "day" => "2026-01-15"}

      assert render("{{ at | time }}", data) == "12:30"
      assert render("{{ at | datetime }}", data) =~ "12:30"
      assert render("{{ at | datetime }}", data) =~ "2026"
      assert render("{{ at | date }}", data) =~ "2026"
      assert render("{{ day | date: \"long\" }}", data) =~ "Ocak"
      new_york = render("{{ at | time }}", data, locale: "en", time_zone: "America/New_York")
      assert new_york =~ "4:30"
    end

    test "TP-27: a date filter refuses a value that is not ISO 8601" do
      {:ok, template} = Engine.parse("{{ at | datetime }}")

      {:ok, context} =
        Context.new(:sms, locale: "tr", time_zone: "UTC", data: %{"at" => "15.01.2026"})

      assert {:error, {:schema_violation, _}} = Engine.render(template, context, :sms)
    end

    test "TP-27: plural uses CLDR categories and an explicit zero" do
      source = "{{ n | plural: zero: \"Mesaj yok\", one: \"# mesaj\", other: \"# mesaj\" }}"

      assert render(source, %{"n" => 0}) == "Mesaj yok"
      assert render(source, %{"n" => 1}) == "1 mesaj"
      assert render(source, %{"n" => 12_000}) == "12.000 mesaj"

      english = "{{ n | plural: one: \"# message\", other: \"# messages\" }}"
      assert render(english, %{"n" => 0}, locale: "en") == "0 messages"
      assert render(english, %{"n" => 1}, locale: "en") == "1 message"
    end

    test "TP-27: Arabic has six plural categories" do
      source =
        ~s({{ n | plural: zero: "z", one: "o", two: "t", few: "f", many: "m", other: "x" }})

      outputs = for n <- [0, 1, 2, 3, 11, 100], do: render(source, %{"n" => n}, locale: "ar")
      assert outputs == ["z", "o", "t", "f", "m", "x"]
    end

    test "TP-27: icu formats classic ICU MessageFormat with named arguments" do
      source =
        "{% capture msg %}{count, plural, =0 {Sepetiniz boş} one {# ürün} other {# ürün}}" <>
          "{% endcapture %}{{ msg | icu: count: n }}"

      assert render(source, %{"n" => 0}) == "Sepetiniz boş"
      assert render(source, %{"n" => 3}) == "3 ürün"
    end

    test "TP-27: icu refuses MessageFormat 2" do
      {:ok, template} = Engine.parse("{{ m | icu: n: 1 }}")

      {:ok, context} =
        Context.new(:sms, locale: "tr", time_zone: "UTC", data: %{"m" => ".input {$n}"})

      assert {:error, {:schema_violation, _}} = Engine.render(template, context, :sms)
    end
  end

  describe "TP-24 escaping once" do
    test "TP-24: HTML values are escaped once, filters included" do
      data = %{"name" => "Tom & <Jerry>"}

      assert render("{{ name }}", data, channel: :email, part: :html) ==
               "Tom &amp; &lt;Jerry&gt;"

      assert render("{{ name | upcase }}", data, channel: :email, part: :html) ==
               "TOM &amp; &lt;JERRY&gt;"

      assert render("{{ name | truncate: 5, \"\" }}", data, channel: :email, part: :html) ==
               "Tom &amp;"

      assert render("{{ name | size }}", data, channel: :email, part: :html) == "13"
    end

    test "TP-24: raw prints a value without escaping when the template allows it" do
      data = %{"html" => "<b>x</b>"}
      assert render("{{ html | raw }}", data, channel: :email, part: :html, allow_raw: true) ==
               "<b>x</b>"
    end

    test "TP-24: text parts lose line breaks" do
      assert render("{{ s }}", %{"s" => "a\r\nb\nc"}, channel: :email, part: :subject) == "a b c"
    end
  end

  describe "TP-45 filter metadata" do
    test "TP-45: the filter set is exactly the decided one" do
      assert Enum.sort(Filters.names()) ==
               Enum.sort(~w(upcase downcase capitalize strip lstrip rstrip truncate replace
                 prepend append default url_encode sms_safe size first last join number percent
                 currency datetime date time plural icu raw))
    end

    property "TP-19: sms_safe never leaves control or direction characters" do
      invisible = ~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

      check all string <- string(:printable) do
        refute Filters.sms_safe(string) =~ invisible
      end
    end

    property "TP-45: truncate never exceeds its length in graphemes" do
      check all string <- string(:printable), length <- integer(3..20) do
        output = render("{{ s | truncate: #{length} }}", %{"s" => string})
        assert String.length(output) <= length
      end
    end
  end
end
