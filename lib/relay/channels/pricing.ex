defmodule Relay.Channels.Pricing do
  @moduledoc """
  The price of a provider's channel unit from its declaration's `pricing` (CH-18, §12.3.5). The table is versioned data: it is part of the provider's declaration in the `channel_event_evidence` data set, so a change is a new audited version and never a deploy, and a decision records the version it used.

  `pricing` carries the `currency`, the `units` per channel (message, segment, session, verification, answered call) and `prices`: rows of `{channel, country, category, unit_price_micros, tier_from}`. A row without `country` or `category` applies to every value of it; the most specific row wins (country and category over country over category over neither), and among those the highest `tier_from` not above the volume already sent in the period.
  """

  @type price :: %{
          currency: String.t(),
          unit: String.t(),
          unit_price_micros: non_neg_integer(),
          tier_from: non_neg_integer()
        }

  # CH-18
  @doc "The unit price of a channel for a destination country, a category (such as a WhatsApp conversation category) and the volume sent so far in the period; `:unpriced` without a matching row."
  @spec price(map() | nil, String.t(), String.t() | nil, String.t() | nil, non_neg_integer()) ::
          {:ok, price()} | :unpriced
  def price(declaration, channel, country, category, volume \\ 0)

  def price(%{"pricing" => %{"currency" => currency, "prices" => rows} = pricing}, c, co, ca, v)
      when is_list(rows) do
    found =
      rows
      |> Enum.filter(&applies?(&1, c, co, ca, v))
      |> Enum.max_by(&{rank(&1), &1["tier_from"] || 0}, fn -> nil end)

    case found do
      nil ->
        :unpriced

      row ->
        {:ok,
         %{
           currency: currency,
           unit: get_in(pricing, ["units", c]) || "message",
           unit_price_micros: row["unit_price_micros"],
           tier_from: row["tier_from"] || 0
         }}
    end
  end

  def price(_declaration, _channel, _country, _category, _volume), do: :unpriced

  # CH-18
  @doc "The cost of `quantity` units at a price, in micros of its currency."
  @spec cost(price(), non_neg_integer()) :: non_neg_integer()
  def cost(%{unit_price_micros: micros}, quantity)
      when is_integer(micros) and is_integer(quantity),
      do: micros * quantity

  defp applies?(row, channel, country, category, volume) do
    row["channel"] == channel and row["country"] in [nil, country] and
      row["category"] in [nil, category] and (row["tier_from"] || 0) <= volume
  end

  defp rank(row), do: {row["country"] != nil, row["category"] != nil}
end
