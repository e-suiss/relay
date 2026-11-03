defmodule Relay.Templates.ContextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Templates.Context
  alias Relay.Templates.Engine
  alias Relay.Templates.Escape

  @base [locale: "tr", time_zone: "Europe/Istanbul"]

  defp context(channel, fields), do: Context.new(channel, Keyword.merge(@base, fields))

  defp render(source, channel, fields) do
    {:ok, template} = Engine.parse(source)
    {:ok, context} = context(channel, fields)
    Engine.render(template, context, channel)
  end

  describe "TP-5 allow-listed plain data" do
    test "TP-5: event data, recipient attributes, brand and helpers are the only names" do
      fields = [
        data: %{"order" => %{"id" => "A1"}},
        recipient: %{"first_name" => "Ayşe"},
        brand: %{"sender_name" => "Suiss"},
        helpers: %{"unsubscribe_url" => "https://example.com/u"}
      ]

      source =
        "{{ order.id }} {{ recipient.first_name }} {{ brand.sender_name }} {{ unsubscribe_url }}"

      assert render(source, :sms, fields) == {:ok, "A1 Ayşe Suiss https://example.com/u"}
    end

    test "TP-5: structs, atom keys, tuples and invalid UTF-8 are refused" do
      for data <- [
            %{"at" => ~U[2026-01-01 00:00:00Z]},
            %{at: "x"},
            %{"pair" => {1, 2}},
            %{"s" => <<0xFF>>},
            %{"pid" => self()}
          ] do
        assert {:error, {:schema_violation, _}} = context(:sms, data: data)
      end

      assert {:error, {:schema_violation, _}} = context(:sms, data: [1])
      assert {:error, {:schema_violation, _}} = context(:sms, helpers: %{"x" => 1})
    end

    test "TP-5: names of the context cannot be taken by event data or helpers" do
      assert {:error, {:schema_violation, _}} = context(:sms, data: %{"brand" => "x"})
      assert {:error, {:schema_violation, _}} = context(:sms, data: %{"recipient" => %{}})
      assert {:error, {:schema_violation, _}} = context(:sms, helpers: %{"brand" => "x"})

      assert {:error, {:schema_violation, _}} =
               context(:sms, data: %{"legal_footer" => "x"}, helpers: %{"legal_footer" => "y"})
    end

    test "TP-5: data deeper than five levels is cut off" do
      deep = %{"a" => %{"b" => %{"c" => %{"d" => %{"e" => %{"f" => "x"}, "k" => "kept"}}}}}
      {:ok, context} = context(:sms, data: deep)

      assert get_in(context.vars, ["a", "b", "c", "d", "e"]) == nil
      assert get_in(context.vars, ["a", "b", "c", "d", "k"]) == "kept"
    end

    test "TP-56: the locale must be supported and the time zone an IANA zone" do
      assert {:error, {:schema_violation, _}} = Context.new(:sms, locale: "ja", time_zone: "UTC")
      assert {:error, {:schema_violation, _}} = Context.new(:sms, locale: "tr", time_zone: "Mars")
      assert {:error, {:schema_violation, _}} = Context.new(:sms, time_zone: "UTC")

      assert {:ok, %Context{locale: "tr-TR"}} =
               Context.new(:sms, locale: "tr-tr", time_zone: "UTC")
    end

    test "TP-13: event data is validated against the event schema when one is given" do
      schema = %{
        "type" => "object",
        "required" => ["code"],
        "properties" => %{"code" => %{"type" => "string", "maxLength" => 6}}
      }

      dialect = "https://json-schema.org/draft/2020-12/schema"
      {:ok, root} = JSV.build(schema, default_meta: dialect)

      assert {:ok, _} = context(:sms, data: %{"code" => "123456"}, schema: root)

      assert {:error, {:schema_violation, _}} =
               context(:sms, data: %{"code" => "1234567"}, schema: root)
    end
  end

  describe "TP-24 escaping by channel" do
    test "TP-24: the escaping mode follows the channel and part" do
      assert Context.escape_mode(:email, :html) == :html
      assert Context.escape_mode(:email, :subject) == :text
      assert Context.escape_mode(:email, :text) == :text
      assert Context.escape_mode(:sms, nil) == :text
      assert Context.escape_mode(:whatsapp, nil) == :text
      assert Context.escape_mode(:push, :body) == :json
      assert Context.escape_mode(:webhook, :payload) == :json
      assert Context.escape_mode(:in_app, :body) == :structured
    end

    test "TP-24: every value is escaped for the context's mode" do
      data = %{"s" => "<a href=\"x\">'R&D'</a>\r\nnext", "list" => ["<b>"]}

      assert {:ok, html} = context(:email, data: data, part: :html)
      assert html.vars["s"] == "&lt;a href=&quot;x&quot;&gt;&#39;R&amp;D&#39;&lt;/a&gt;\r\nnext"
      assert html.vars["list"] == ["&lt;b&gt;"]

      assert {:ok, text} = context(:email, data: data, part: :subject)
      assert text.vars["s"] == "<a href=\"x\">'R&D'</a> next"

      assert {:ok, json} = context(:push, data: data)
      assert json.vars["s"] == data["s"]

      assert {:ok, inbox} = context(:in_app, data: data)
      assert inbox.escape == :structured
      assert inbox.vars["s"] == data["s"]
    end

    test "TP-24: a trusted helper is Relay's own output and is not escaped" do
      helpers = %{
        "legal_footer" => {:trusted, "<p>Suiss A.Ş.</p>"},
        "unsubscribe_url" => "https://example.com/u?a=1&b=2"
      }

      source = "{{ legal_footer }}{{ unsubscribe_url }}"

      assert render(source, :email, helpers: helpers, part: :html) ==
               {:ok, "<p>Suiss A.Ş.</p>https://example.com/u?a=1&amp;b=2"}
    end

    property "TP-24: HTML escaping is reversed exactly" do
      check all string <- string(:printable) do
        escaped = Escape.escape(string, :html)
        refute escaped =~ ~r/[<>"']/
        assert Escape.unescape(escaped, :html) == string
      end
    end

    property "TP-24: text escaping leaves no line break" do
      check all string <- string(:printable) do
        refute Escape.escape(string, :text) =~ ~r/[\r\n\x{2028}\x{2029}\x{0085}]/u
      end
    end
  end

  describe "TP-29 direction" do
    test "TP-29: printed values are isolated in RTL locales except on SMS" do
      fields = [locale: "ar", data: %{"name" => "Ali", "n" => 3}]

      assert render("مرحبا {{ name }}", :push, fields) == {:ok, "مرحبا \u2068Ali\u2069"}
      assert render("مرحبا {{ name }}", :in_app, fields) == {:ok, "مرحبا \u2068Ali\u2069"}
      assert render("مرحبا {{ name }}", :sms, fields) == {:ok, "مرحبا Ali"}

      assert render("Hi {{ name }}", :push, locale: "tr", data: %{"name" => "Ali"}) ==
               {:ok, "Hi Ali"}
    end

    test "TP-29: the direction of a locale" do
      assert Context.direction("ar") == :rtl
      assert Context.direction("fa-IR") == :rtl
      assert Context.direction("tr-TR") == :ltr
    end
  end

  describe "TP-14 criticality" do
    test "TP-14: fallback takes its default and is counted, optional and decorative are null" do
      variables = %{
        "customer.name" => %{class: :fallback, default: "Değerli müşterimiz"},
        "note" => %{class: :optional},
        "badge" => %{class: :decorative},
        "code" => %{class: :required}
      }

      {:ok, context} = context(:sms, data: %{"customer" => %{}}, variables: variables)

      assert context.vars["customer"]["name"] == "Değerli müşterimiz"
      assert Map.fetch(context.vars, "note") == {:ok, nil}
      assert Map.fetch(context.vars, "badge") == {:ok, nil}
      refute Map.has_key?(context.vars, "code")
      assert context.fallbacks == ["customer.name"]

      source = "Merhaba {{ customer.name }}{% if note %} {{ note }}{% endif %}{{ badge }}"
      {:ok, template} = Engine.parse(source)
      assert Engine.render(template, context, :sms) == {:ok, "Merhaba Değerli müşterimiz"}
    end

    test "TP-14: a present value is never replaced and array elements are filled one by one" do
      variables = %{"items[].label" => %{class: :fallback, default: "-"}}
      data = %{"items" => [%{}, %{"label" => "a"}, %{}]}
      {:ok, context} = context(:sms, data: data, variables: variables)

      assert Enum.map(context.vars["items"], & &1["label"]) == ["-", "a", "-"]
      assert context.fallbacks == ["items[].label", "items[].label"]
    end

    test "TP-14: a missing parent is not created" do
      variables = %{"order.note" => %{class: :optional}}
      {:ok, context} = context(:sms, data: %{}, variables: variables)
      refute Map.has_key?(context.vars, "order")
    end
  end
end
