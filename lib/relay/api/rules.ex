defmodule Relay.Api.Rules do
  @moduledoc """
  The rule dictionary on the server API (X-12, X-1, DS-47): every rule in force, ordered by `rule_id`, with its reason, kind, outcome, the detail fields a decision records for it, whether it is deprecated and its one sentence explanation in each language the dictionary carries. A surface shows the dictionary's sentence for a `rule_id` and never writes its own.
  """

  @type answer :: {:ok, {100..599, [{String.t(), String.t()}], map()}} | {:error, Relay.Error.t()}

  # X-12
  # X-1
  # DS-47
  @doc "Lists the rules of the dictionary in force (`listRules`)."
  @spec list() :: answer()
  def list do
    rules =
      Relay.Rules.dictionary()
      |> Map.values()
      |> Enum.sort_by(& &1["id"])
      |> Enum.map(&view/1)

    {:ok, {200, [], %{"object" => "rule_dictionary", "data" => rules}}}
  end

  # X-12
  # DS-47
  @doc "The API view of one dictionary rule."
  @spec view(map()) :: map()
  def view(rule) do
    %{
      "rule_id" => rule["id"],
      "reason" => rule["reason"],
      "kind" => rule["kind"],
      "outcome" => rule["outcome"],
      "detail" => rule["detail"] || [],
      "deprecated" => rule["deprecated"] == true,
      "description" => rule["description"] || %{}
    }
  end
end
