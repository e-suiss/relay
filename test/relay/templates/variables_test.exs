defmodule Relay.Templates.VariablesTest do
  use ExUnit.Case, async: true

  alias Relay.Templates.Engine
  alias Relay.Templates.Variables

  @schema %{
    "type" => "object",
    "properties" => %{
      "customer" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "maxLength" => 40,
            "x-relay-criticality" => "fallback",
            "default" => "Değerli müşterimiz"
          }
        }
      },
      "order" => %{
        "type" => "object",
        "required" => ["items"],
        "properties" => %{
          "id" => %{"type" => "string", "maxLength" => 20},
          "note" => %{
            "type" => "string",
            "maxLength" => 200,
            "x-relay-criticality" => "optional"
          },
          "items" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 50,
            "items" => %{"$ref" => "#/$defs/item"}
          },
          "total" => %{"$ref" => "#/$defs/money"},
          "placed_at" => %{"type" => "string", "format" => "date-time"},
          "count" => %{"type" => "integer", "maximum" => 1000}
        }
      }
    },
    "$defs" => %{
      "item" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "maxLength" => 40}}
      },
      "money" => %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "string", "maxLength" => 15},
          "currency" => %{"type" => "string", "enum" => ["TRY", "EUR"]}
        }
      }
    }
  }

  @digit %{"type" => "integer", "maximum" => 9}

  defp parse!(source) do
    {:ok, template} = Engine.parse(source)
    template
  end

  defp codes(source, schema \\ @schema, opts \\ []) do
    source |> parse!() |> Variables.validate(schema, opts) |> Enum.map(&{&1.code, &1.path})
  end

  describe "TP-17 static extraction" do
    test "TP-17: paths read always and only conditionally" do
      source =
        "{{ order.id }}{% if order.note %}{{ order.note }}{% endif %}" <>
          "{% for item in order.items %}{{ item.name }}{{ forloop.index }}{% endfor %}" <>
          "{% assign c = customer %}{{ c.name }}" <>
          "{% capture x %}{{ order.count }}{% endcapture %}{{ x }}"

      assert Variables.extract(parse!(source)) == %{
               always: [
                 "customer",
                 "customer.name",
                 "order.count",
                 "order.id",
                 "order.items",
                 "order.note"
               ],
               conditional: ["order.items[].name"]
             }
    end

    test "TP-17: filter arguments and dynamic keys are reads too" do
      source = "{{ a | default: b }}{{ prices[currency] }}"

      assert Variables.extract(parse!(source)).always == ["a", "b", "currency", "prices[]"]
    end

    test "TP-17: paths and segments convert both ways" do
      assert Variables.segments("order.items[].name") == ["order", "items", :index, "name"]
      assert Variables.path(["order", "items", :index, "name"]) == "order.items[].name"
      assert Variables.segments("m[][]") == ["m", :index, :index]
    end
  end

  describe "TP-13 TP-14 TP-15 TP-16 publication validation" do
    test "TP-13: a template within the schema has no findings" do
      source =
        "{{ order.id }}{% if order.note %}{{ order.note }}{% endif %}" <>
          "{% for item in order.items %}{{ item.name }}{% endfor %}" <>
          "{{ order.total | currency }}" <>
          "{{ order.placed_at | datetime }}{{ order.items.size }}{{ customer.name }}" <>
          "{{ brand.sender_name }}{{ unsubscribe_url }}{{ order.count | number }}"

      assert codes(source) == []
    end

    test "TP-14: an undeclared variable is an error" do
      assert codes("{{ order.missing }}") == [{"undeclared_variable", "order.missing"}]
      assert codes("{{ brand.secret }}") == [{"undeclared_variable", "brand.secret"}]
      assert codes("{{ legal_footer.x }}") == [{"undeclared_variable", "legal_footer.x"}]

      assert codes("{{ recipient.first_name }}") ==
               [{"undeclared_variable", "recipient.first_name"}]

      recipient = %{
        "type" => "object",
        "properties" => %{"first_name" => %{"type" => "string", "maxLength" => 50}}
      }

      assert codes("{{ recipient.first_name }}", @schema, recipient_schema: recipient) == []
    end

    test "E-83: a link is read as links.<rel> with a valid rel" do
      assert codes("{{ links.primary }}{{ links.order_2 }}") == []
      assert codes("{{ links.primary.href }}") == [{"undeclared_variable", "links.primary.href"}]
      assert codes("{{ links }}") == [{"undeclared_variable", "links"}]
    end

    test "TP-14: an optional variable is read only inside a condition" do
      assert codes("{{ order.note }}") == [{"optional_unguarded", "order.note"}]
      assert codes("{% if order.note %}{{ order.note }}{% endif %}") == []
    end

    test "TP-14: a fallback needs a default and the class must be known" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "string", "maxLength" => 5, "x-relay-criticality" => "fallback"},
          "b" => %{"type" => "string", "maxLength" => 5, "x-relay-criticality" => "maybe"}
        }
      }

      assert codes("{{ a }}{{ b }}", schema) == [
               {"fallback_default_missing", "a"},
               {"criticality_invalid", "b"}
             ]
    end

    test "TP-15 TP-16: strings need maxLength, numbers maximum, required arrays minItems" do
      schema = %{
        "type" => "object",
        "required" => ["list"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "n" => %{"type" => "number"},
          "list" => %{"type" => "array", "maxItems" => 3, "items" => @digit},
          "open" => %{"type" => "array", "items" => @digit},
          "state" => %{"type" => "string", "enum" => ["a", "b"]}
        }
      }

      assert codes("{{ title }}{{ n }}{{ state }}", schema) == [
               {"max_length_missing", "title"},
               {"maximum_missing", "n"}
             ]

      assert codes("{% for i in list %}{{ i }}{% endfor %}", schema) == [
               {"min_items_missing", "list"},
               {"min_items_missing", "list[]"}
             ]

      assert codes("{% for i in open %}{{ i }}{% endfor %}", schema) ==
               [{"max_items_missing", "open"}]
    end

    test "TP-16: money is {amount: string, currency} and the date filters read date-time" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "price" => %{
            "type" => "object",
            "properties" => %{
              "amount" => %{"type" => "number", "maximum" => 10},
              "currency" => %{"type" => "string", "maxLength" => 3}
            }
          },
          "day" => %{"type" => "string", "maxLength" => 10}
        }
      }

      assert {"money_amount_not_string", "price"} in codes("{{ price | currency }}", schema)
      assert {"money_shape", "price"} in codes("{{ price | currency }}", schema)
      assert codes("{{ order.id | currency }}") == [{"money_shape", "order.id"}]
      assert codes("{{ day | datetime }}", schema) == [{"date_time_format", "day"}]
      assert codes("{{ order.id | date }}") == [{"date_time_format", "order.id"}]
    end

    test "TP-16: a date-time printed without a date filter is a warning" do
      [finding] = "{{ order.placed_at }}" |> parse!() |> Variables.validate(@schema)
      assert %{code: "unformatted_date_time", severity: :warning} = finding
    end
  end

  describe "TP-14 criticality declarations" do
    test "TP-14: the declarations of a schema by path" do
      assert Variables.criticality(@schema) == %{
               "customer.name" => %{class: :fallback, default: "Değerli müşterimiz"},
               "order.note" => %{class: :optional}
             }
    end
  end

  describe "TP-15 worst case" do
    test "TP-15: the largest output over the boundary samples" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "maxLength" => 10}}
      }

      template = parse!("Merhaba {{ name }}")

      assert Variables.worst_case(template, schema, :sms, locale: "tr") ==
               {:ok, %{characters: 18, graphemes: 17, bytes: 30, sample: "emoji"}}
    end

    test "TP-15: a variable the samples cannot supply is reported" do
      template = parse!("{{ brand.sender_name }}")

      assert {:error, {"max", {:missing_variable, "brand.sender_name"}}} =
               Variables.worst_case(template, %{"type" => "object"}, :sms, locale: "tr")
    end
  end
end
