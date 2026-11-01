defmodule Relay.Rules do
  @moduledoc """
  Runtime lookup of the rule dictionary: the reason family, kind, outcome, detail fields and the one sentence explanation of a recorded `rule_id`. The active installation version of the `rule_dictionary` data set is used; an installation without one, or one whose version cannot be read, falls back to the version bundled with the release (`Relay.RuleDictionary.bundled/0`), so a lookup never depends on the database being reachable. The "why did I not get this" views show the dictionary sentence and never write their own.
  """

  use Boundary, top_level?: true, deps: [Relay, Relay.Datasets], exports: []

  alias Relay.RuleDictionary

  @dataset "rule_dictionary"

  # DS-47 (2)
  # DS-47 (3)
  @doc "Returns the dictionary entry of a recorded rule id (a reference after `:` is ignored)."
  @spec entry(String.t()) :: {:ok, RuleDictionary.entry()} | {:error, Relay.Error.t()}
  def entry(rule_id) when is_binary(rule_id) do
    if RuleDictionary.rule_id?(rule_id),
      do: RuleDictionary.lookup(dictionary(), rule_id),
      else: {:error, Relay.Error.new(:invalid_rule_id, "not a rule identifier")}
  end

  # DS-25
  @doc "Returns the reason family of a recorded rule id."
  @spec reason(String.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def reason(rule_id) do
    with {:ok, entry} <- entry(rule_id), do: {:ok, entry["reason"]}
  end

  # X-12
  @doc "Returns the explanation of a recorded rule id in `language`: `en` or `tr`."
  @spec describe(String.t(), String.t()) :: {:ok, String.t()} | {:error, Relay.Error.t()}
  def describe(rule_id, language) when language in ["en", "tr"] do
    with {:ok, entry} <- entry(rule_id), do: {:ok, entry["description"][language]}
  end

  @doc "Returns true when the rule id is in the dictionary."
  @spec known?(String.t()) :: boolean()
  def known?(rule_id), do: match?({:ok, _}, entry(rule_id))

  @doc "The dictionary in use: the active installation version, or the bundled one."
  @spec dictionary() :: RuleDictionary.t()
  def dictionary do
    case Relay.Datasets.active(Relay.Datasets.installation_scope(), @dataset) do
      {:ok, %{content: %{"rules" => _} = content}} -> RuleDictionary.index(content)
      _other -> RuleDictionary.index(RuleDictionary.bundled())
    end
  rescue
    _error -> RuleDictionary.index(RuleDictionary.bundled())
  end
end
