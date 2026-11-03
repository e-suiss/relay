defmodule Relay.Templates.EngineTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Context
  alias Relay.Templates.Engine

  defp render(source, data, opts \\ []) do
    channel = Keyword.get(opts, :channel, :sms)
    {:ok, template} = Engine.parse(source, allow_raw: Keyword.get(opts, :allow_raw, false))

    {:ok, context} =
      Context.new(channel,
        locale: Keyword.get(opts, :locale, "tr"),
        time_zone: "Europe/Istanbul",
        data: data
      )

    Engine.render(template, context, channel)
  end

  defp codes(source, opts \\ []) do
    {:error, findings} = Engine.parse(source, opts)
    Enum.map(findings, & &1.code)
  end

  describe "TP-45 allowed tags" do
    test "TP-45: every allowed tag renders" do
      source =
        "{% assign n = name %}{% capture c %}Hi {{ n }}{% endcapture %}{{ c }}|" <>
          "{% if count > 1 %}many{% elsif count == 1 %}one{% else %}none{% endif %}|" <>
          "{% unless flag %}off{% endunless %}|" <>
          "{% case status %}{% when \"a\" %}A{% else %}B{% endcase %}|" <>
          "{% for i in items limit: 2 offset: 1 %}{{ i }}{% endfor %}|" <>
          "{% for i in none %}x{% else %}empty{% endfor %}|" <>
          "{% raw %}{{ x }}{% endraw %}|{% comment %}hidden{% endcomment %}" <>
          "{% for i in items %}{% if i == 3 %}{% break %}{% endif %}{{ i }}{% endfor %}|" <>
          "{% for i in items %}{% if i == 2 %}{% continue %}{% endif %}{{ i }}{% endfor %}"

      data = %{
        "name" => "Ada",
        "count" => 2,
        "flag" => false,
        "status" => "a",
        "items" => [1, 2, 3, 4],
        "none" => []
      }

      assert render(source, data) == {:ok, "Hi Ada|many|off|A|23|empty|{{ x }}|12|134"}
    end

    test "TP-4: include, render and every tag outside the set are parse errors" do
      for source <- [
            "{% include 'header' %}",
            "{% render 'header' %}",
            "{% cycle 'a', 'b' %}",
            "{% tablerow i in items %}{{ i }}{% endtablerow %}",
            "{% increment n %}",
            "{% decrement n %}",
            "{% echo name %}",
            "{% # note %}"
          ] do
        assert "tag_not_allowed" in codes(source), source
      end
    end

    test "TP-45: the liquid tag is a parse error" do
      assert "tag_not_allowed" in codes("{% liquid assign x = 1 %}")
      assert "tag_not_allowed" in codes("a\n{%- liquid\n echo x\n-%}")
    end

    test "TP-45: for takes only limit and offset and iterates only over data" do
      assert "for_reversed" in codes("{% for i in items reversed %}{{ i }}{% endfor %}")
      assert "range_not_allowed" in codes("{% for i in (1..5) %}{{ i }}{% endfor %}")
      assert "range_not_allowed" in codes("{{ (1..3) }}")
    end
  end

  describe "TP-45 filter set" do
    test "TP-45: arithmetic, escape and other standard filters do not exist" do
      for filter <- ~w(plus minus times divided_by modulo escape abs sort map where) do
        assert codes("{{ x | #{filter}: 1 }}") == ["filter_not_allowed"], filter
      end

      assert codes("{{ x | escape }}") == ["filter_not_allowed"]
    end

    test "TP-45: a wrong argument count or named arguments are parse errors" do
      assert codes("{{ x | upcase: 1 }}") == ["filter_arity"]
      assert codes("{{ x | replace: \"a\" }}") == ["filter_arity"]
      assert codes("{{ x | upcase: a: 1 }}") == ["filter_arity"]
    end

    test "TP-45: truncate takes a constant length and the date filters a known style" do
      assert codes("{{ x | truncate: n }}") == ["filter_argument"]
      assert codes("{{ x | truncate: -1 }}") == ["filter_argument"]
      assert codes("{{ x | datetime: \"weird\" }}") == ["filter_argument"]
      assert codes("{{ x | number: 11 }}") == ["filter_argument"]
      assert codes("{{ x | plural: one: \"#\" }}") == ["filter_argument"]
      assert codes("{{ x | plural: one: \"#\", other: n }}") == ["filter_argument"]
      assert {:ok, _} = Engine.parse("{{ x | truncate: 5, \"…\" }}{{ x | date: \"long\" }}")
    end

    test "TP-24: raw needs the template's allow_raw flag" do
      assert codes("{{ x | raw }}") == ["raw_not_allowed"]
      assert {:ok, %Engine{allow_raw: true}} = Engine.parse("{{ x | raw }}", allow_raw: true)
    end
  end

  describe "TP-6 static limits" do
    test "TP-6: the source is at most 256 KB" do
      assert codes(String.duplicate("a", 256 * 1024 + 1)) == ["source_too_large"]
      assert {:ok, _} = Engine.parse(String.duplicate("a", 256 * 1024))
    end

    test "TP-6: at most 10 loops" do
      loop = "{% for i in xs %}{{ i }}{% endfor %}"
      assert {:ok, _} = Engine.parse(String.duplicate(loop, 10))
      assert codes(String.duplicate(loop, 11)) == ["too_many_loops"]
    end

    test "TP-6: loops nest at most 2 deep" do
      two = "{% for a in xs %}{% for b in a %}{{ b }}{% endfor %}{% endfor %}"

      three =
        "{% for a in xs %}{% for b in a %}{% for c in b %}{{ c }}" <>
          "{% endfor %}{% endfor %}{% endfor %}"

      assert {:ok, _} = Engine.parse(two)
      assert codes(three) == ["loops_too_deep"]
    end

    test "TP-6: at most 5,000 nodes" do
      assert {:ok, _} = Engine.parse(String.duplicate("{{ x }}", 5_000))
      assert codes(String.duplicate("{{ x }}", 5_001)) == ["too_many_nodes"]
    end

    test "TP-6: nodes count text, output, filters, tags and conditions" do
      {:ok, template} = Engine.parse("a{{ x | upcase }}{% if y %}b{% endif %}")
      assert Engine.stats(template) == %{nodes: 6, loops: 0, loop_depth: 0}
    end

    test "TP-5: nested access is at most 5 deep" do
      assert {:ok, _} = Engine.parse("{{ a.b.c.d.e }}")
      assert codes("{{ a.b.c.d.e.f }}") == ["access_too_deep"]
      assert codes("{{ [x] }}") == ["dynamic_root"]
    end

    test "TP-4: the source must be UTF-8" do
      assert codes(<<"{{ x }}", 0xFF>>) == ["invalid_utf8"]
    end
  end

  describe "TP-4 strict rendering" do
    test "TP-4: an undefined variable stops the render" do
      assert render("Kod {{ code }}", %{}) == {:error, {:missing_variable, "code"}}
      assert render("{{ order.id }}", %{"order" => %{}}) ==
               {:error, {:missing_variable, "order.id"}}
    end

    test "TP-5: an array index outside the array is a missing variable" do
      assert render("{{ items[1] }}", %{"items" => ["a", "b"]}) == {:ok, "b"}
      assert {:error, {:missing_variable, _}} = render("{{ items[5] }}", %{"items" => ["a"]})
    end

    test "TP-5: an object cannot be printed" do
      assert {:error, {:schema_violation, _}} = render("{{ order }}", %{"order" => %{"id" => 1}})
    end

    test "TP-24: a context built for another channel is refused" do
      {:ok, template} = Engine.parse("{{ x }}")
      {:ok, context} = Context.new(:email, locale: "tr", time_zone: "UTC", data: %{"x" => 1})

      assert_raise ArgumentError, fn -> Engine.render(template, context, :sms) end
    end
  end
end
