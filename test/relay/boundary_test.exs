defmodule Relay.BoundaryTest do
  use ExUnit.Case, async: true

  @contexts [
    Relay.Ingest,
    Relay.Workflow,
    Relay.Policy,
    Relay.Templates,
    Relay.Channels,
    Relay.Delivery,
    Relay.Inbox,
    Relay.Webhooks,
    Relay.Agents,
    Relay.Tenancy,
    Relay.Audit,
    Relay.Platform
  ]

  defp boundary(module) do
    [definition] = Keyword.fetch!(module.__info__(:attributes), Boundary)
    definition.opts
  end

  test "T-56: every core context is its own top-level boundary" do
    for context <- @contexts do
      opts = boundary(context)
      assert opts[:top_level?], "#{inspect(context)} is not a top-level boundary"
    end
  end

  test "T-56: contexts depend only on the shared kernel until a dependency is decided" do
    for context <- @contexts do
      assert boundary(context)[:deps] == [Relay], "#{inspect(context)} has undecided dependencies"
    end
  end

  test "T-57: contexts export nothing but their root module" do
    for context <- @contexts do
      assert boundary(context)[:exports] == [], "#{inspect(context)} exports internal modules"
    end
  end

  test "T-56: the kernel depends on no context" do
    assert boundary(Relay)[:deps] == []
  end
end
