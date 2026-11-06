defmodule Relay.Channels.Whatsapp.Bundled do
  @moduledoc """
  The WhatsApp data sets Relay ships, compiled in: the newest bundled version of `whatsapp_messaging_limits` and every bundled version of `whatsapp_rate_cards`, one per quarter. The send path decides with the active version of a data set; the bundled content is what the tests and an installation without an active version read.
  """

  @names ["whatsapp_rate_cards", "whatsapp_messaging_limits"]

  root = Path.join([__DIR__, "..", "..", "..", "..", "priv", "datasets"])

  versions =
    for name <- @names, path <- Path.wildcard(Path.join([root, name, "v*.json"])) do
      @external_resource path
      number = path |> Path.basename(".json") |> String.trim_leading("v") |> String.to_integer()
      {name, number, path |> File.read!() |> Jason.decode!()}
    end

  @versions versions

  @doc "The names of the WhatsApp data sets."
  @spec names() :: [String.t(), ...]
  def names, do: @names

  @doc "The content of the newest bundled version of a WhatsApp data set."
  @spec content(String.t()) :: map()
  def content(name) when name in @names do
    {_name, _number, content} =
      @versions |> Enum.filter(&(elem(&1, 0) == name)) |> Enum.max_by(&elem(&1, 1))

    content
  end

  @doc "Every bundled rate card, oldest first."
  @spec rate_cards() :: [map()]
  def rate_cards do
    for {"whatsapp_rate_cards", _number, content} <- Enum.sort_by(@versions, &elem(&1, 1)),
        do: content
  end
end
