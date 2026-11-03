defmodule Relay.Templates.TermSets do
  @moduledoc """
  The dictionary data sets of the publication gate as lint entries (TP-46, TP-54): `sensitive_terms` and `promotional_terms`. An installation reads the active version of each data set; the newest version bundled with the release is compiled in here as the fallback when an installation has no active version. A deprecated term is never matched, and a promotional phrase becomes an entry whose `"term"` is the phrase (`Relay.Templates.Lint.Terms`).
  """

  @names ["sensitive_terms", "promotional_terms"]

  root = Path.join([__DIR__, "..", "..", "..", "priv", "datasets"])

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

  @doc "The names of the dictionary data sets."
  @spec names() :: [String.t()]
  def names, do: @names

  # TP-46
  # TP-54
  @doc "The content of the newest bundled version of a dictionary data set."
  @spec bundled(String.t()) :: map()
  def bundled(name) when name in @names, do: Map.fetch!(@bundled, name)

  # TP-46
  # TP-54
  @doc "The lint entries of a dictionary data set's content: active terms with their locale and category; a promotional phrase is the term."
  @spec entries(map()) :: [map()]
  def entries(%{"terms" => terms}) when is_list(terms) do
    for %{"term" => term} = entry <- terms, entry["deprecated"] != true do
      %{"term" => term, "locale" => entry["locale"], "category" => entry["category"]}
    end
  end

  def entries(%{"phrases" => phrases}) when is_list(phrases) do
    for %{"phrase" => phrase} = entry <- phrases, entry["deprecated"] != true do
      %{"term" => phrase, "locale" => entry["locale"], "category" => entry["category"]}
    end
  end

  def entries(_content), do: []
end
