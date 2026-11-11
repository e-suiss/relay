defmodule Relay.Delivery.ProjectionTest do
  use ExUnit.Case, async: true

  alias Relay.Delivery.Projection

  defp d(kind, rank, stage),
    do: %{"failure_kind" => kind, "delivery_rank" => rank, "window_stage" => stage}

  describe "DS-14 DS-17 the external projection" do
    test "DS-17: definite terminals, failures, delivery and the window rule in that order" do
      cases = [
        {d(nil, 0, 0), "queued"},
        {d(nil, 1, 0), "sent"},
        {d(nil, 1, 1), "unknown_pending"},
        {d(nil, 1, 2), "unknown"},
        {d(nil, 2, 2), "delivered"},
        {d("bounced", 2, 0), "failed"},
        {d("failed", 1, 2), "failed"},
        {d("skipped", 0, 0), "skipped"},
        {d("expired", 0, 0), "expired"},
        {d("cancelled", 0, 0), "cancelled"}
      ]

      for {delivery, status} <- cases, do: assert(Projection.status(delivery) == status)
    end

    test "DS-14: the statuses are the nine values of the contract" do
      assert Projection.statuses() ==
               ~w(queued sent delivered unknown_pending unknown failed skipped expired cancelled)
    end

    test "DS-9: a notification's view counts its deliveries per status" do
      deliveries = [d(nil, 2, 0), d(nil, 2, 0), d(nil, 1, 1), d("skipped", 0, 0)]

      assert Relay.Delivery.status_counts(deliveries) == %{
               "delivered" => 2,
               "unknown_pending" => 1,
               "skipped" => 1
             }
    end

    test "DS-3, DS-14: engagement shows a likely bot's click as bot" do
      assert %{"clicked_by" => "bot", "read_at" => nil} =
               Projection.engagement(%{"clicked_by" => "likely_bot", "clicked_at" => "t"})
    end
  end
end
