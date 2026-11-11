defmodule RelayWeb.Api.ReportTest do
  use Relay.DataCase, async: false

  alias RelayTest.DeliveryFixture
  alias RelayTest.IngestFixture, as: F

  setup_all do
    day = Date.add(DateTime.to_date(Relay.Clock.utc_now()), -1)
    from = DateTime.new!(Date.beginning_of_month(day), ~T[00:00:00], "Etc/UTC")
    to = DateTime.new!(Date.add(Date.end_of_month(day), 1), ~T[00:00:00], "Etc/UTC")
    conn = Relay.SqlCase.connect(:admin)

    %{rows: [[result]]} =
      Postgrex.query!(conn, "SELECT relay_private.partition_create($1, $2, $3)", [
        "usage_records",
        from,
        to
      ])

    GenServer.stop(conn)
    assert result in ["created", "exists"]
    :ok
  end

  defp today, do: Relay.Clock.utc_now() |> DateTime.to_date()

  defp path(report, from, to),
    do: "/v1/reports/#{report}?from=#{Date.to_iso8601(from)}&to=#{Date.to_iso8601(to)}"

  describe "DS-35 report endpoints" do
    test "DS-35, DS-36: the delivery and skip reports answer the rollups of the period" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      n = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, n, :succeeded, delivery_rank: :delivered)
      {:ok, _counts} = Relay.Delivery.recompute_report_day(scope, today())
      token = F.token(scope)

      tomorrow = Date.add(today(), 1)
      body = F.body(F.request(:get, path("deliveries", today(), tomorrow), token), 200)
      assert %{"object" => "delivery_report", "rows" => [row]} = body
      assert %{"channel" => "email", "accepted" => 1, "delivered" => 1} = row

      skips = F.body(F.request(:get, path("skips", today(), tomorrow), token), 200)
      assert %{"object" => "skip_report", "rows" => []} = skips
    end

    test "DS-53, CH-18: the cost report lists the usage records of the period" do
      %{scope: scope} = DeliveryFixture.sendable!()
      yesterday = Date.add(today(), -1)

      usage = %{
        id: Relay.Id.generate(),
        usage_day: yesterday,
        channel: :sms,
        provider: "netgsm",
        destination_country: "TR",
        outcome: :accepted,
        is_test: false,
        quantity: 2,
        attempt_count: 2,
        sms_segments: 3,
        cost_micros: 240,
        currency: "TRY",
        billable_unit: "segment",
        billable_units: 3
      }

      {:ok, :recorded} = Relay.Delivery.record_usage(scope, usage)
      body = F.body(F.request(:get, path("costs", yesterday, today()), F.token(scope)), 200)

      assert %{"object" => "cost_report", "rows" => [row]} = body

      assert %{
               "provider" => "netgsm",
               "billable_unit" => "segment",
               "billable_units" => 3,
               "cost_micros" => "240",
               "currency" => "TRY"
             } = row
    end

    test "DS-35: a period ends after it starts and covers at most 92 days" do
      %{scope: scope} = DeliveryFixture.sendable!()
      token = F.token(scope)

      for {from, to} <- [{today(), today()}, {today(), Date.add(today(), 93)}] do
        assert F.body(F.request(:get, path("deliveries", from, to), token), 422)["code"] ==
                 "validation_failed"
      end

      missing = F.request(:get, "/v1/reports/costs?from=2026-11-01", token)
      assert F.body(missing, 422)["code"] == "validation_failed"
    end
  end
end
