defmodule Relay.CLI.YamlTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.CLI.DefinitionFile
  alias Relay.CLI.Yaml

  defp round_trip(value) do
    {:ok, decoded} = value |> Yaml.encode() |> IO.iodata_to_binary() |> Yaml.decode()
    decoded
  end

  describe "WF-59 X-33 YAML definition files" do
    test "WF-59: a definition reads back as the same JSON value" do
      value = %{
        "name" => "Sipariş kargolandı",
        "event_schema" => %{
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "object",
          "properties" => %{"order id" => %{"type" => "string"}},
          "required" => []
        },
        "on" => true,
        "yes" => false,
        "null" => nil,
        "y" => "n",
        "1st" => "1",
        "flags" => %{},
        "numbers" => [1, -2, 0, 2.5],
        "texts" => ["true", "null", "", "  padded ", "line\nbreak", "tab\tand \"quote\"", "#x"],
        "unprintable" => "del\u007f next\u0085 sep  emoji 😀",
        "steps" => [
          %{"type" => "channel", "key" => "inbox", "template" => "welcome"},
          %{"type" => "condition", "branches" => [%{"when" => %{"eq" => [1, 1]}, "steps" => []}]},
          [["nested"], []]
        ]
      }

      assert round_trip(value) == value
    end

    test "X-33: keys are sorted, strings quoted and the bytes stable" do
      text =
        %{"steps" => [%{"type" => "channel", "key" => "a"}], "name" => "W", "on" => 1}
        |> Yaml.encode()
        |> IO.iodata_to_binary()

      assert text == """
             name: "W"
             "on": 1
             steps:
               - key: "a"
                 type: "channel"
             """
    end

    property "WF-59: any JSON value of strings, integers and booleans reads back unchanged" do
      leaf =
        StreamData.one_of([
          StreamData.string(:printable, max_length: 20),
          StreamData.integer(),
          StreamData.boolean(),
          StreamData.constant(nil)
        ])

      json =
        StreamData.tree(leaf, fn child ->
          StreamData.one_of([
            StreamData.list_of(child, max_length: 4),
            StreamData.map_of(StreamData.string(:printable, max_length: 10), child, max_length: 4)
          ])
        end)

      top = StreamData.map_of(StreamData.string(:alphanumeric), json, max_length: 4)

      check all value <- top do
        assert round_trip(value) == value
      end
    end

    @tag :tmp_dir
    test "X-33: a JSON file is written with sorted keys and a trailing newline",
         %{tmp_dir: dir} do
      path = Path.join(dir, "routes/standard.json")
      body = %{"tree" => %{"single" => ["in_app", "email"]}, "name" => "Standard", "key" => "a"}

      assert IO.iodata_to_binary(DefinitionFile.render(path, body)) == """
             {
               "key": "a",
               "name": "Standard",
               "tree": {
                 "single": [
                   "in_app",
                   "email"
                 ]
               }
             }
             """
    end
  end
end
