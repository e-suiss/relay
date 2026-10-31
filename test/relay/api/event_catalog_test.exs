defmodule Relay.Api.EventCatalogTest do
  use ExUnit.Case, async: true

  @path Path.expand("../../../contracts/asyncapi/events.yaml", __DIR__)
  @name ~r/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/

  defp catalog, do: YamlElixir.read_from_file!(@path)

  defp ref(%{"$ref" => "#/components/messages/" <> key}), do: key

  defp channel_ref(%{"$ref" => "#/channels/" <> rest}) do
    [channel, "messages", key] = String.split(rest, "/")
    {channel, key}
  end

  describe "API-3 API-59 TN-47 single event catalog" do
    test "API-3, API-59: x-relay-event-names is the sorted set of every message name" do
      doc = catalog()
      names = doc["components"]["messages"] |> Map.values() |> Enum.map(& &1["name"])

      assert doc["x-relay-event-names"] == names |> Enum.uniq() |> Enum.sort()
    end

    test "API-3: every event name is noun.verb_past and is the message title" do
      for {key, message} <- catalog()["components"]["messages"] do
        assert message["name"] =~ @name, key
        assert message["title"] == message["name"], key
        assert String.ends_with?(key, "." <> message["name"]), key
      end
    end

    test "API-3, TN-47: every message is on a channel and every channel message is in an operation" do
      doc = catalog()
      messages = doc["components"]["messages"]

      on_channels =
        for {channel, %{"messages" => listed}} <- doc["channels"],
            {key, reference} <- listed do
          assert ref(reference) == key, "#{channel} #{key}"
          assert Map.has_key?(messages, key), "#{channel} #{key}"
          {channel, key}
        end

      operated =
        for {_name, op} <- doc["operations"], reference <- op["messages"] do
          "#/channels/" <> channel = op["channel"]["$ref"]
          assert {^channel, _key} = channel_ref(reference)
        end

      assert Enum.sort(on_channels) == Enum.sort(operated)
      assert MapSet.new(on_channels, &elem(&1, 1)) == MapSet.new(Map.keys(messages))
    end
  end
end
