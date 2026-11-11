defmodule Relay.Delivery.ProjectionTest do
  use ExUnit.Case, async: true

  alias Relay.Delivery.Projection

  describe "DS-14 the engagement projection" do
    test "DS-3, DS-14: engagement shows a likely bot's click as bot" do
      assert %{"clicked_by" => "bot", "read_at" => nil} =
               Projection.engagement(%{"clicked_by" => "likely_bot", "clicked_at" => "t"})
    end
  end
end
