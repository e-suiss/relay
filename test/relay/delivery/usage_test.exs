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
        "sms_segments" => 6,
        "billable_unit" => "segment",
        "billable_units" => 6
      },
      attrs
    )
  end

  defp priced(attrs, volumes), do: Store.price(row(attrs), pricer(), volumes)

  defp counted(attrs) do
    Map.merge(
      %{
        "channel" => "sms",
        "provider" => "netgsm",
        "outcome" => "accepted",
        "attempt_count" => 3,
        "segment_units" => 7,
        "answered_calls" => 2,
        "call_seconds" => 95
      },
      attrs
    )
  end

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
      assert %{"billable_unit" => "segment", "billable_units" => 3} = row
      assert row["whatsapp_category"] == nil
    end

    test "DS-53: a failed attempt bills nothing and an e-mail attempt bills its recipient" do
      %{scope: scope, delivery_id: id} = DeliveryFixture.sendable!()
      first = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, first, :failed, failure_class: "transient")
      second = DeliveryFixture.started_attempt!(scope, id)
      DeliveryFixture.finish(scope, id, second, :succeeded)

      assert {:ok, [accepted, failed]} = Relay.Delivery.usage_rows(scope, today())
      assert %{"billable_unit" => "recipient", "billable_units" => 1} = accepted
      assert %{"outcome" => "failed", "billable_units" => 0} = failed
      assert accepted["voice_seconds"] == nil
    end
  end

  describe "DS-53 billable units" do
    test "DS-53: each channel bills its own unit" do
      assert %{"billable_unit" => "segment", "billable_units" => 7} = Store.billable(counted(%{}))

      voice = Store.billable(counted(%{"channel" => "voice"}))
      assert %{"billable_unit" => "answered_call", "billable_units" => 2} = voice
      assert voice["voice_seconds"] == 95

      for {channel, unit} <- [
            {"whatsapp", "message"},
            {"email", "recipient"},
            {"push", "attempt"},
            {"web_push", "attempt"},
            {"in_app", "attempt"},
            {"webhook", "attempt"}
          ] do
        row = Store.billable(counted(%{"channel" => channel}))
        assert %{"billable_unit" => ^unit, "billable_units" => 3} = row
        assert row["voice_seconds"] == nil
      end
    end

    test "DS-53: uncertain attempts bill, failed and simulated attempts do not" do
      assert %{"billable_units" => 7} = Store.billable(counted(%{"outcome" => "uncertain"}))
      assert %{"billable_units" => 0} = Store.billable(counted(%{"outcome" => "failed"}))
      assert %{"billable_units" => 0} = Store.billable(counted(%{"provider" => "fake"}))

      voice = Store.billable(counted(%{"channel" => "voice", "provider" => "fake"}))
      assert %{"billable_units" => 0, "voice_seconds" => 0} = voice
      refute Map.has_key?(voice, "segment_units")
    end

    test "DS-53, OP-38: a row without billable units is never priced" do
      simulated = Store.billable(counted(%{"provider" => "fake"}))
      refute Map.has_key?(Store.price(simulated, pricer(), %{}), "cost_micros")
    end
  end

  describe "CH-18 usage cost" do
    test "CH-18, OP-38: an SMS row costs its segments at the country price and the month's tier" do
      assert %{"cost_micros" => 480, "currency" => "TRY"} = priced(%{}, %{})
      assert %{"cost_micros" => 300} = priced(%{}, %{{"sms", "netgsm"} => 1500})
      assert %{"cost_micros" => 600} = priced(%{"destination_country" => "DE"}, %{})
    end

    test "CH-18, OP-38: an uncertain row is priced, a failed or unpriced row has no cost" do
      assert %{"cost_micros" => 480} = priced(%{"outcome" => "uncertain"}, %{})
      failed = %{"outcome" => "failed", "billable_units" => 0}
      refute Map.has_key?(priced(failed, %{}), "cost_micros")
      refute Map.has_key?(priced(%{"billable_units" => nil}, %{}), "cost_micros")
      refute Map.has_key?(priced(%{"channel" => "push"}, %{}), "cost_micros")

      email = %{
        "channel" => "email",
        "destination_country" => nil,
        "sms_segments" => nil,
        "billable_unit" => "recipient",
        "billable_units" => 2
      }

      assert %{"cost_micros" => 14} = priced(email, %{})
    end
  end
end
