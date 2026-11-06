defmodule Relay.Channels.PricingTest do
  use ExUnit.Case, async: true

  alias Relay.Channels.Pricing

  defp declaration do
    %{
      "pricing" => %{
        "currency" => "USD",
        "units" => %{"whatsapp" => "message", "sms" => "segment"},
        "prices" => [
          %{"channel" => "sms", "country" => nil, "category" => nil, "unit_price_micros" => 9000},
          %{
            "channel" => "sms",
            "country" => "TR",
            "category" => nil,
            "unit_price_micros" => 4000
          },
          %{
            "channel" => "sms",
            "country" => "TR",
            "category" => nil,
            "unit_price_micros" => 3000,
            "tier_from" => 100_000
          },
          %{
            "channel" => "whatsapp",
            "country" => "TR",
            "category" => "marketing",
            "unit_price_micros" => 12_000
          },
          %{
            "channel" => "whatsapp",
            "country" => nil,
            "category" => "utility",
            "unit_price_micros" => 5000
          }
        ]
      }
    }
  end

  describe "CH-18 price tables" do
    test "CH-18: the most specific row wins and a volume tier lowers the price" do
      assert {:ok, %{unit_price_micros: 4000, unit: "segment", currency: "USD"}} =
               Pricing.price(declaration(), "sms", "TR", nil)

      assert {:ok, %{unit_price_micros: 3000, tier_from: 100_000}} =
               Pricing.price(declaration(), "sms", "TR", nil, 250_000)

      assert {:ok, %{unit_price_micros: 9000}} = Pricing.price(declaration(), "sms", "DE", nil)
    end

    test "CH-18: country and category break the price down" do
      assert {:ok, %{unit_price_micros: 12_000}} =
               Pricing.price(declaration(), "whatsapp", "TR", "marketing")

      assert {:ok, %{unit_price_micros: 5000}} =
               Pricing.price(declaration(), "whatsapp", "TR", "utility")

      assert Pricing.price(declaration(), "whatsapp", "DE", "marketing") == :unpriced
      assert Pricing.price(nil, "sms", "TR", nil) == :unpriced
    end

    test "CH-18: the cost is the unit price times the quantity" do
      {:ok, price} = Pricing.price(declaration(), "sms", "TR", nil)
      assert Pricing.cost(price, 3) == 12_000
    end
  end
end
