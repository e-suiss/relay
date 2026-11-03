defmodule Relay.Templates.Lint.Sensitive do
  @moduledoc """
  The sensitive term scan of the publish gate (TP-21, TP-46). The static text and the variable names of a variant are matched against the `sensitive_terms` dataset entries (see `Relay.Templates.Lint.Terms` for the entry shape and the matching). A match does not block by itself: the tenant confirms the sensitivity class while seeing the matched terms, and a match without that confirmation is a hard finding. A template without a sensitivity class is a hard finding too.
  """

  alias Relay.Templates.Finding
  alias Relay.Templates.Lint.Terms

  @classes [:public, :personal, :sensitive]

  # TP-21
  # TP-46
  @doc "The dataset entries that match the static texts or the variable names."
  @spec matches([String.t()], [String.t()], [Terms.entry()], String.t() | nil) :: [Terms.match()]
  def matches(texts, variables, entries, locale),
    do: Terms.scan(texts ++ Enum.map(variables, &Terms.words/1), entries, locale)

  # TP-21
  # TP-32
  # TP-46
  @doc "Publish gate check. Options: `:locale`, `:channel`, `:sensitivity` (`:public`, `:personal`, `:sensitive` or `nil`) and `:confirmed` (the tenant confirmed the class against the matched terms, default `false`)."
  @spec check([String.t()], [String.t()], [Terms.entry()], keyword()) :: [Finding.t()]
  def check(texts, variables, entries, opts \\ []) do
    locale = Keyword.get(opts, :locale)
    fields = [channel: Keyword.get(opts, :channel), locale: locale]
    found = matches(texts, variables, entries, locale)

    class_finding(Keyword.get(opts, :sensitivity), fields) ++
      match_finding(found, Keyword.get(opts, :confirmed, false), fields)
  end

  defp class_finding(class, _fields) when class in @classes, do: []
  defp class_finding(_class, fields), do: [Finding.new(:sensitivity_missing, :hard, fields)]

  defp match_finding([], _confirmed, _fields), do: []
  defp match_finding(_found, true, _fields), do: []

  defp match_finding(found, _confirmed, fields),
    do: [Finding.new(:sensitive_terms, :hard, [detail: %{terms: found}] ++ fields)]
end
