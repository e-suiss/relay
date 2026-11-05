defmodule Relay.Channels.Email.Bundled do
  @moduledoc """
  The e-mail data sets Relay ships, compiled in: the newest bundled version of each. The send path decides with the active version of a data set (`Relay.Datasets.decide/3`); the bundled content is the reference the tests and an installation without an active version read.
  """

  @names [
    "email_bounce_codes",
    "email_bulk_sender_rules",
    "email_reputation",
    "email_warmup_plans"
  ]

  root = Path.join([__DIR__, "..", "..", "..", "..", "priv", "datasets"])

  versions =
    for name <- @names, path <- Path.wildcard(Path.join([root, name, "v*.json"])) do
      @external_resource path
      number = path |> Path.basename(".json") |> String.trim_leading("v") |> String.to_integer()
      {name, number, path}
    end

  bundled =
    versions
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {name, rows} ->
      {_name, _number, path} = Enum.max_by(rows, &elem(&1, 1))
      {name, path |> File.read!() |> Jason.decode!()}
    end)

  @bundled bundled

  @doc "The names of the e-mail data sets."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The content of the newest bundled version of an e-mail data set."
  @spec content(String.t()) :: map()
  def content(name) when name in @names, do: Map.fetch!(@bundled, name)
end
