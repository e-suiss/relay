defmodule Relay.Templates.Lint.Promotion do
  @moduledoc """
  The promotion leak check of the publish gate (TP-12, TP-54). The static text of a template bound to a `transactional` or `operational` category is matched against the call-to-action phrases of the `promotional_terms` dataset (entry shape and matching in `Relay.Templates.Lint.Terms`); any match is a hard finding. Phrases, not single words, are listed, so a receipt line such as "kampanya indirimi: 20 TL" does not match. Templates of other classes are not checked.
  """

  alias Relay.Templates.Finding
  alias Relay.Templates.Lint.Terms

  @checked ["transactional", "operational"]

  # TP-12
  # TP-32
  # TP-54
  @doc "Publish gate check. Options: `:message_class` (the category class), `:locale`, `:channel`."
  @spec check([String.t()], [Terms.entry()], keyword()) :: [Finding.t()]
  def check(texts, entries, opts \\ []) do
    locale = Keyword.get(opts, :locale)

    with true <- Keyword.get(opts, :message_class) in @checked,
         [_ | _] = found <- Terms.scan(texts, entries, locale) do
      fields = [channel: Keyword.get(opts, :channel), locale: locale, detail: %{terms: found}]
      [Finding.new(:promotion, :hard, fields)]
    else
      _none -> []
    end
  end
end
