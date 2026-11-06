defmodule Relay.Channels.Whatsapp.Pricing do
  @moduledoc """
  WhatsApp message cost (CH-18, CH-58, CH-60). The rate card is the versioned data set `whatsapp_rate_cards`: one version per calendar quarter, because Meta changes the card only at a quarter's start. A price the card does not hold is `:unknown`, never zero, and a message inside the customer service window is never assumed free (CH-58).

  Once Meta reports a message, the `pricing` object of its status webhook is the source of truth: it is stored whole, and its `type` says whether the message was billed (`regular`) or free (`free_customer_service`, `free_entry_point`); a billed message is priced by its `category` from the card of the quarter it was sent in (`cost/3`).
  """

  @free ~w(free_customer_service free_entry_point)

  @type cost :: {:ok, non_neg_integer()} | :unknown

  # CH-18
  # CH-58
  @doc "The price in millionths of the card's currency of one message of `category` to `country`: the country's own rate, else the card's market row without a country only when the card names no rate for the country at all; `:unknown` otherwise."
  @spec price(map(), String.t() | nil, String.t()) :: cost()
  def price(%{"rates" => rates}, country, category) when is_list(rates) do
    own = Enum.filter(rates, &(&1["country"] == country and country != nil))

    rows =
      if own == [], do: Enum.filter(rates, &(&1["country"] == nil)), else: own

    case Enum.filter(rows, &(&1["category"] == category)) do
      [%{"unit_price_micros" => micros}] -> {:ok, micros}
      _none_or_ambiguous -> :unknown
    end
  end

  # CH-60
  @doc "The cost of a reported message from its `pricing` object: zero when its type is free, the card's price of its category when billed, `:unknown` otherwise."
  @spec cost(map(), map() | nil, String.t() | nil) :: cost()
  def cost(card, %{"type" => type}, _country) when type in @free and is_map(card), do: {:ok, 0}

  def cost(card, %{"billable" => false}, _country) when is_map(card), do: {:ok, 0}

  def cost(card, %{"category" => category}, country) when is_binary(category),
    do: price(card, country, String.downcase(category))

  def cost(_card, _pricing, _country), do: :unknown

  # CH-18
  @doc "The quarter a date falls in, as the first day of the quarter; a rate card version applies from such a day."
  @spec quarter(Date.t()) :: Date.t()
  def quarter(%Date{year: year, month: month}),
    do: Date.new!(year, div(month - 1, 3) * 3 + 1, 1)

  # CH-18
  @doc "Picks the card that applies on `date` among versions: the latest whose `effective_from` is on or before it."
  @spec card([map()], Date.t()) :: {:ok, map()} | :none
  def card(cards, %Date{} = date) when is_list(cards) do
    cards
    |> Enum.filter(&(Date.compare(Date.from_iso8601!(&1["effective_from"]), date) != :gt))
    |> Enum.max_by(& &1["effective_from"], fn -> nil end)
    |> case do
      nil -> :none
      card -> {:ok, card}
    end
  end
end
