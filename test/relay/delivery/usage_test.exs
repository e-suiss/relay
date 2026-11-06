defmodule Relay.Delivery.UsageTest.Unpriced do
  @moduledoc false

  def usage_pricing do
    {:ok, fn _provider, _channel, _country, _category, _volume -> :unpriced end}
  end
end

defmodule Relay.Delivery.UsageTest do
  use Relay.DataCase, async: false

  alias Relay.Delivery.Usage.Store
  alias RelayTest.DeliveryFixture

  def usage_pricing, do: {:error, :prices_unavailable}

  defp today, do: Relay.Clock.utc_now() |> DateTime.to_date()

  defp pricer do
    tr = %{"channel" => "sms", "country" => "TR"}

    pricing = %{
      "pricing" => %{
        "currency" => "TRY",
        "units" => %{"sms" => "segment"},
        "prices" => [
          %{"channel" => "sms", "unit_price_micros" => 100},
          Map.put(tr, "unit_price_micros", 80),
          Map.merge(tr, %{"unit_price_micros" => 50, "tier_from" => 1000}),
          %{"channel" => "email", "unit_price_micros" => 7}
        ]
      }
    }

    fn _provider, channel, country, category, volume ->
      Relay.Channels.price(pricing, channel, country, category, volume)
    end
  end

  defp row(attrs) do
    Map.merge(
      %{
        "channel" => "sms",
        "provider" => "netgsm",
        "destination_country" => "TR",
        "whatsapp_category" => nil,
        "outcome" => "accepted",
        "attempt_count" => 2,
        "sms_segments" => 6
      },
      attrs
    )
  end

  defp priced(attrs, volumes), do: Store.price(row(attrs), pricer(), volumes)

  describe "C-88 OP-38 daily usage records" do
    test "INV-49, OP-38: finished attempts of a day are counted per channel, provider and outcome" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      first = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, first, :failed, failure_class: "transient")
      second = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, second, :succeeded)

      assert {:ok, rows} = Relay.Delivery.usage_rows(scope, today())

      assert [
               %{"provider" => "mailpit", "outcome" => "accepted", "quantity" => 1} = accepted,
               %{"provider" => "mailpit", "outcome" => "failed", "attempt_count" => 1}
             ] = rows

      assert accepted["is_test"] == false
      assert {:ok, []} = Relay.Delivery.usage_rows(scope, Date.add(today(), -1))
    end

    test "OP-38: no day is written while the prices cannot be read" do
      previous = Application.get_env(:relay, Relay.Delivery, [])
      on_exit(fn -> Application.put_env(:relay, Relay.Delivery, previous) end)
      Application.put_env(:relay, Relay.Delivery, Keyword.put(previous, :pricing, __MODULE__))

      assert {:error, :prices_unavailable} = Relay.Delivery.close_usage_day(today())
    end

    test "C-88: a day that has not closed is not written" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      n = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, n, :succeeded)

      previous = Application.get_env(:relay, Relay.Delivery, [])
      on_exit(fn -> Application.put_env(:relay, Relay.Delivery, previous) end)
      unpriced = Keyword.put(previous, :pricing, Relay.Delivery.UsageTest.Unpriced)
      Application.put_env(:relay, Relay.Delivery, unpriced)

      counts = Relay.Delivery.close_usage_day(today())

      assert counts.day_open >= 1
      assert counts.recorded == 0
      assert counts.conflict == 0
    end

    test "OP-38: an uncertain attempt is counted apart from accepted ones" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      n = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, n, :unknown, failure_class: "unknown")

      assert {:ok, [%{"outcome" => "uncertain", "quantity" => 1, "attempt_count" => 1}]} =
               Relay.Delivery.usage_rows(scope, today())
    end

    test "OP-38: the attempt's destination country and SMS segments reach its usage row" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!(delivery: [channel: :sms])
      n = DeliveryFixture.started_attempt!(scope, id)
      meter = %{destination_country: "TR", sms_segments: 3}
      assert {:ok, :metered} = Relay.Delivery.meter_attempt(scope, id, n, meter)
      DeliveryFixture.finish(scope, id, n, :succeeded)

      assert {:ok, [row]} = Relay.Delivery.usage_rows(scope, today())

      assert %{"channel" => "sms", "destination_country" => "TR", "sms_segments" => 3} = row
      assert row["whatsapp_category"] == nil
    end
  end

  describe "CH-18 usage cost" do
    test "CH-18, OP-38: an SMS row costs its segments at the country price and the month's tier" do
      assert %{"cost_micros" => 480, "currency" => "TRY"} = priced(%{}, %{})
      assert %{"cost_micros" => 300} = priced(%{}, %{{"sms", "netgsm"} => {10, 1500}})
      assert %{"cost_micros" => 600} = priced(%{"destination_country" => "DE"}, %{})
    end

    test "CH-18, OP-38: an uncertain row is priced, a failed or unpriced row has no cost" do
      assert %{"cost_micros" => 480} = priced(%{"outcome" => "uncertain"}, %{})
      refute Map.has_key?(priced(%{"outcome" => "failed"}, %{}), "cost_micros")
      refute Map.has_key?(priced(%{"sms_segments" => nil}, %{}), "cost_micros")
      refute Map.has_key?(priced(%{"channel" => "push"}, %{}), "cost_micros")

      email = %{"channel" => "email", "destination_country" => nil, "sms_segments" => nil}
      assert %{"cost_micros" => 14} = priced(email, %{})
    end
  end
end
