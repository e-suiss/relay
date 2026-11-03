defmodule Relay.Templates.PublishGateTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.PublishGate

  @sensitive [%{"term" => "borc", "locale" => "tr", "category" => "finance"}]
  @promotional [%{"term" => "indirim kodu", "locale" => "tr", "category" => nil}]
  @mjml_html ~s(<html lang="tr"><head><meta name="color-scheme" content="light dark"></head>) <>
               ~s(<body><p>Merhaba {{ order.id }}</p></body></html>)

  @schema %{
    "type" => "object",
    "properties" => %{
      "order" => %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string", "maxLength" => 20}}
      }
    }
  }

  defp compiled(_source), do: {:ok, @mjml_html}

  defp gate(cells, extra \\ %{}) do
    definition =
      Map.merge(
        %{"default_locale" => "tr", "sensitivity" => "public", "cells" => cells},
        Map.get(extra, :definition, %{})
      )

    input = %{
      definition: definition,
      message_class: "transactional",
      schemas: [@schema],
      sensitive_terms: @sensitive,
      promotional_terms: @promotional,
      compile: &compiled/1
    }

    PublishGate.template(Map.merge(input, Map.delete(extra, :definition)))
  end

  defp sms(body), do: %{"sms" => %{"tr" => %{"body" => body}}}

  defp email(fields \\ %{}) do
    base = %{"subject" => "Sipariş", "html" => "<mjml/>", "text" => "Metin"}
    %{"email" => %{"tr" => Map.merge(base, fields)}}
  end

  defp schema(properties), do: %{"type" => "object", "properties" => properties}
  defp string(max), do: %{"type" => "string", "maxLength" => max}

  defp checks(result, level), do: for(%{level: ^level} = f <- result.findings, do: f.check)

  describe "TP-32 hard gates" do
    test "TP-32, TP-13: a clean SMS template passes with its variable usage and measures" do
      result = gate(sms("Siparişiniz {{ order.id }} kargoda"))

      assert result.findings == []
      assert result.variables == %{"always" => ["order.id"], "conditional" => []}
      assert %{"sms" => %{"tr" => %{sms: %{encoding: _, segments: 1}}}} = result.measures
    end

    test "TP-6, TP-45: a cell that does not parse is a hard finding with its pointer" do
      result = gate(sms("{% include 'x' %}"))
      assert [%{check: :parse, level: :hard, channel: :sms, pointer: "/body"}] = result.findings
    end

    test "TP-14: an undeclared variable and an unbounded string are hard findings" do
      unbounded = schema(%{"name" => %{"type" => "string"}})
      result = gate(sms("{{ missing }} {{ name }}"), %{schemas: [unbounded]})
      codes = for %{check: :variables, detail: detail} <- result.findings, do: detail.code

      assert "undeclared_variable" in codes
      assert "max_length_missing" in codes
    end

    test "TP-14: without a workflow schema every event variable is undeclared" do
      result = gate(sms("{{ order.id }}"), %{schemas: []})
      assert [%{check: :variables, detail: %{code: "undeclared_variable"}}] = result.findings
    end

    test "TP-56: a cell in an unsupported locale is a hard finding" do
      result = gate(%{"sms" => %{"zz" => %{"body" => "x"}}})
      assert %{check: :locale_not_supported, locale: "zz"} = hd(result.findings)
    end

    test "TP-22: an email without its plain text body is a hard finding" do
      result = gate(email(%{"text" => " "}))
      assert :email_plain_text in checks(result, :hard)
    end

    test "TP-8: MJML that does not compile is hard and Liquid runs on the compiled HTML" do
      error = Relay.Error.new(:mjml_parse, "bad", %{line: 2, column: 3})
      result = gate(email(), %{compile: fn _source -> {:error, error} end})
      failures = Enum.filter(result.findings, &(&1.check == :mjml_compile))

      assert [%{detail: %{code: "mjml_parse", line: 2, column: 3}}] = failures

      ok = gate(email())
      assert "order.id" in ok.variables["always"]
      assert ok.measures["email"]["tr"].bytes > 0
    end

    test "TP-58: social, carousel and accordion elements without explicit images are hard" do
      social = ~s(<mj-social-element name="github" href="https://e.x">G</mj-social-element>)

      mjml =
        ~s(<mjml><mj-body><mj-section><mj-column><mj-social>) <>
          social <>
          ~s(</mj-social><mj-carousel><mj-carousel-image src="https://e.x/1.png" />) <>
          ~s(</mj-carousel>) <>
          ~s(<mj-accordion><mj-accordion-element></mj-accordion-element></mj-accordion>) <>
          ~s(</mj-column></mj-section></mj-body></mjml>)

      findings = gate(email(%{"html" => mjml})).findings
      elements = for %{check: :mjml_default_asset, detail: detail} <- findings, do: detail.element

      assert Enum.sort(elements) == ["mj-accordion", "mj-carousel", "mj-social-element"]

      explicit =
        ~s(<mj-social-element name="github" src="https://e.x/g.png">G</mj-social-element>) <>
          ~s(<mj-carousel left-icon="https://e.x/l.png" right-icon="https://e.x/r.png">) <>
          ~s(<mj-accordion icon-wrapped-url="https://e.x/a.png") <>
          ~s( icon-unwrapped-url="https://e.x/b.png">)

      assert PublishGate.asset_findings(explicit) == []
    end

    test "TP-21, TP-46: a missing class and an unconfirmed term are hard; confirmation clears it" do
      missing = gate(sms("Merhaba"), %{definition: %{"sensitivity" => nil}})
      assert :sensitivity_missing in checks(missing, :hard)

      term = gate(sms("Borcunuz ödendi"))
      assert [%{check: :sensitive_terms, detail: %{terms: [%{term: "borc"}]}}] = term.findings

      approval = %{
        "matched_terms" => ["borc"],
        "approved_by" => "ayse",
        "approved_at" => "2026-11-03T00:00:00Z"
      }

      approved = %{definition: %{"sensitivity_approval" => approval}}
      confirmed = gate(sms("Borcunuz ödendi"), approved)
      assert confirmed.findings == []
    end

    test "TP-20: a push variant over 1024 characters or 4096 bytes in the worst case is hard" do
      cell = %{"title" => "Bilgi", "body" => "{{ note }}"}
      long = schema(%{"note" => string(1100)})
      characters = gate(%{"push" => %{"tr" => cell}}, %{schemas: [long]})
      assert :push_characters in checks(characters, :hard)

      wide = schema(%{"a" => string(1020), "b" => string(1020), "c" => string(1020)})
      cell = %{"title" => "{{ a }}", "subtitle" => "{{ b }}", "body" => "{{ c }}"}
      bytes = gate(%{"push" => %{"tr" => cell}}, %{schemas: [wide]})
      assert :push_payload_size in checks(bytes, :hard)
    end

    test "TP-12, TP-54: a promotional call in a transactional template is hard; marketing is not" do
      assert :promotion in checks(gate(sms("İndirim kodu: YAZ20")), :hard)

      body = sms("İndirim kodu: YAZ20 {{ legal_footer }}")
      refute :promotion in checks(gate(body, %{message_class: "marketing"}), :hard)
    end

    test "TP-33, TP-55: a commercial template needs the legal footer helper and the brand fields" do
      marketing = %{message_class: "marketing", country: "TR"}
      assert :legal_footer_missing in checks(gate(sms("Kampanya"), marketing), :hard)

      footer = gate(sms("Kampanya {{ legal_footer }}"), marketing)
      assert [%{check: :legal_footer_fields, detail: %{missing: missing}}] = footer.findings
      assert "legal_name" in missing

      brand = %{"legal_name" => "Örnek A.Ş.", "mersis" => "0123456789012345"}
      complete = gate(sms("Kampanya {{ legal_footer }}"), Map.put(marketing, :brand, brand))
      assert complete.findings == []
    end

    test "TP-59: an icu message without every plural category of the locale is hard" do
      count = schema(%{"n" => %{"type" => "integer", "maximum" => 9}})

      source =
        "{% capture msg %}{n, plural, other {# ürün}}{% endcapture %}{{ msg | icu: n: n }} " <>
          ~s({{ "{n, plural, one {#} other {#}}" | icu: n: n }})

      result = gate(%{"sms" => %{"ar" => %{"body" => source}}}, %{schemas: [count]})
      icu = for %{check: :icu_categories, detail: detail} <- result.findings, do: detail.missing

      assert ["few", "many", "one", "two", "zero"] in icu
      assert ["few", "many", "two", "zero"] in icu
    end

    test "TP-19: an emoji in SMS template text is a hard finding" do
      assert :sms_emoji in checks(gate(sms("Kargoda \u{1F69A}")), :hard)
    end

    test "TP-30: a machine translated cell without approval blocks the publication" do
      cell = %{"body" => "Shipped", "machine_translated" => true}
      result = gate(%{"sms" => %{"tr" => %{"body" => "Kargoda"}, "en" => cell}})
      assert [%{check: :translation_unapproved, locale: "en"}] = result.findings

      approved = Map.put(cell, "translation_approved_by", "ayse")
      assert gate(%{"sms" => %{"tr" => %{"body" => "Kargoda"}, "en" => approved}}).findings == []
    end
  end

  describe "TP-32 warnings" do
    test "TP-30, TP-32: locales of one channel that read different variables are a warning" do
      cells = %{"sms" => %{"tr" => %{"body" => "{{ a }}"}, "en" => %{"body" => "{{ b }}"}}}
      result = gate(cells, %{schemas: [schema(%{"a" => string(5), "b" => string(5)})]})

      assert [%{check: :locale_variables, level: :warning, detail: %{missing: missing}}] =
               result.findings

      assert missing == %{"en" => ["a"], "tr" => ["b"]}
    end

    test "TP-15, TP-18: an SMS that can need more than one segment is one warning" do
      result = gate(sms("Merhaba {{ name }}"), %{schemas: [schema(%{"name" => string(200)})]})

      assert [%{check: :sms_segments, level: :warning, detail: detail}] = result.findings
      assert detail.segments > 1
      assert %{"sms" => %{"tr" => %{sms: %{encoding_unverified_provider: _}}}} = result.measures
    end

    test "TP-15, TP-23: a WhatsApp parameter over its limit in the worst case is a warning" do
      parameters = [%{"name" => "note", "value" => "{{ note }}"}]
      cell = %{"template_name" => "order_v1", "parameters" => parameters}
      long = schema(%{"note" => string(2000)})
      result = gate(%{"whatsapp" => %{"tr" => cell}}, %{schemas: [long]})

      assert :whatsapp_parameter_length in checks(result, :warning)
      assert checks(result, :hard) == []
    end

    test "TP-22, TP-34: email size and the accessibility lint are warnings" do
      html = "<html><body>" <> String.duplicate("<p>x</p>", 9_000) <> ~s(<img src="a.png">)
      result = gate(email(), %{compile: fn _source -> {:ok, html <> "</body></html>"} end})
      warnings = checks(result, :warning)

      assert :email_html_size in warnings
      assert :a11y_lang in warnings
      assert :a11y_img_alt in warnings
      assert :email_color_scheme in warnings
      assert checks(result, :hard) == []
    end
  end

  describe "TP-35 layouts and partials" do
    test "TP-8, TP-58: a layout compiles and reads only brand fields and helpers" do
      ok = fn _source -> {:ok, "<html>{{ brand.logo_url }} {{ content }}</html>"} end
      definition = %{"mjml" => "<mjml/>", "text_footer" => "{{ legal_footer }}"}

      assert %{findings: [], compiled: "<html>" <> _} =
               PublishGate.layout(definition, compile: ok)

      bad = %{"mjml" => "<mjml/>", "text_header" => "{{ order.id }}"}

      assert [%{check: :variables, detail: %{code: "undeclared_variable"}}] =
               PublishGate.layout(bad, compile: ok).findings

      failing = fn _source -> {:error, Relay.Error.new(:mjml_parse, "bad")} end
      assert [%{check: :mjml_compile}] = PublishGate.layout(definition, compile: failing).findings
    end

    test "TP-35, TP-59: a partial parses in supported locales with complete icu forms" do
      ok = %{"default_locale" => "tr", "bodies" => %{"tr" => "Merhaba", "en" => "Hello"}}
      assert PublishGate.partial(ok).findings == []

      bad = %{"default_locale" => "tr", "bodies" => %{"tr" => "{% include 'x' %}", "zz" => "x"}}
      checks = Enum.map(PublishGate.partial(bad).findings, & &1.check)

      assert :locale_not_supported in checks
      assert :parse in checks
    end
  end

  describe "TP-8 the bundled MJML compiler" do
    @tag :integration
    test "TP-8, TP-32: the compiled HTML is what the gate parses and renders" do
      mjml =
        ~s(<mjml lang="tr"><mj-body><mj-section><mj-column><mj-text>) <>
          ~s(Siparişiniz {{ order.id }}</mj-text></mj-column></mj-section></mj-body></mjml>)

      result = gate(email(%{"html" => mjml}), %{compile: &Relay.Templates.compile_mjml/1})

      assert checks(result, :hard) == []
      assert result.compiled["tr"] =~ "Siparişiniz {{ order.id }}"
    end
  end
end
