defmodule Relay.Topics.AudienceTest do
  use ExUnit.Case, async: true

  alias Relay.Topics.Audience

  @server "contracts/openapi/server.yaml"
  @schemas "contracts/openapi/components/schemas.yaml"

  defp member(n, external_id), do: %{recipient_id: n, topic_id: :topic, external_id: external_id}

  describe "WF-52 L-31 frozen recipient set" do
    test "L-31: a member named directly is not added again and is marked also_direct" do
      targets = [{:require, "a"}, {:topic, "t"}, {:implicit, "b", %{"email" => "b@example.com"}}]
      members = [member(1, "a"), member(2, "c"), member(3, "b")]

      assert {:ok, recipients, marked} = Audience.merge(targets, members, 100)

      assert recipients == [
               {:require, "a"},
               {:implicit, "b", %{"email" => "b@example.com"}},
               {:require, "c"}
             ]

      assert Enum.map(marked, & &1.also_direct) == [true, false, true]
    end

    test "API-35: an audience above the event's recipient limit is too large" do
      members = for n <- 1..3, do: member(n, "m#{n}")

      assert {:too_large, 4} = Audience.merge([{:require, "x"}, {:topic, "t"}], members, 3)
      assert {:ok, _recipients, _marked} = Audience.merge([{:topic, "t"}], members, 3)
    end

    test "WF-52: a child topic reaches its active parent; earlier topics win" do
      child = %{"id" => :child, "parent_id" => :parent, "parent_state" => "active"}
      orphan = %{"id" => :orphan, "parent_id" => :gone, "parent_state" => "archived"}
      parent = %{"id" => :parent, "parent_id" => nil, "parent_state" => nil}

      assert Audience.paths(child) == [:child, :parent]
      assert Audience.paths(orphan) == [:orphan]
      assert Audience.all_paths([child, parent, orphan]) == [:child, :parent, :orphan]
    end
  end

  describe "WF-53 explicit matching" do
    test "WF-53: unknown topics come before archived ones and carry their pointers" do
      rows = [%{"id" => 1, "key" => "old", "state" => "archived"}]

      assert {:error, :unknown, [%{pointer: "/to/2"}]} =
               Audience.check([{"old", 0}, {"new", 2}], rows)

      assert {:error, :archived, [%{pointer: "/to/0", code: "not_allowed"}]} =
               Audience.check([{"old", 0}], rows)
    end

    test "WF-53: a topic key is matched exactly, never as a pattern" do
      rows = [%{"id" => 1, "key" => "project:1", "state" => "active"}]

      assert {:error, :unknown, _errors} = Audience.check([{"project:*", 0}], rows)
      assert {:ok, [%{"id" => 1}]} = Audience.check([{"project:1", 0}, {"project:1", 1}], rows)
    end

    test "WF-53: each named topic without a subscriber yields a warning with its rule" do
      topics = [
        %{"id" => :a, "key" => "a", "parent_id" => nil},
        %{"id" => :b, "key" => "b", "parent_id" => nil}
      ]

      assert [%{"code" => "topic_no_subscribers", "pointer" => "/to/1", "detail" => detail}] =
               Audience.unreached([{"a", 0}, {"b", 1}], topics, %{a: 2})

      assert detail =~ "audience.no_subscribers"
    end
  end

  describe "WF-54 E-67 no segment engine" do
    test "E-67, WF-54: an audience is named by subscribers and topics only, never by a query" do
      server = YamlElixir.read_from_file!(@server)
      schemas = YamlElixir.read_from_file!(@schemas)

      refute Enum.any?(Map.keys(server["paths"]), &String.contains?(&1, "segment"))
      assert Map.keys(schemas["TopicTarget"]["properties"]) == ["topic"]

      assert schemas["TopicSubscribers"]["properties"]["subscribers"]["items"] ==
               %{"$ref" => "#/ExternalId"}
    end
  end
end
