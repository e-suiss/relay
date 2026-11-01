defmodule Relay.RuleDictionary do
  @moduledoc """
  The rule dictionary as data: every `rule_id` a decision records comes from it. A rule identifier is lower case, underscore separated parts joined by dots (`preference.category_channel`); a reference to a record may follow after `:` (`killswitch.bulk_cancel:<id>`) and the dictionary is looked up by the part before it. Spec decision identifiers are never rule identifiers. The dictionary is the versioned data set `rule_dictionary`; the newest version bundled with the release is compiled in here as the fallback when an installation has no active version.
  """

  dir = Path.join([__DIR__, "..", "..", "priv", "datasets", "rule_dictionary"])
  paths = Path.wildcard(Path.join(dir, "v*.json"))
  for path <- paths, do: @external_resource(path)

  newest =
    Enum.max_by(paths, fn path ->
      path |> Path.basename(".json") |> String.trim_leading("v") |> String.to_integer()
    end)

  @bundled newest |> File.read!() |> Jason.decode!()

  @id ~r/\A[a-z][a-z0-9_]*(\.[a-z0-9][a-z0-9_]*)+\z/
  @rule_id ~r/\A[a-z][a-z0-9_]*([.:][A-Za-z0-9_-]+)*\z/

  @type entry :: %{required(String.t()) => term()}
  @type t :: %{String.t() => entry()}

  # DS-47 (2)
  @doc "The content of the newest bundled `rule_dictionary` version."
  @spec bundled() :: map()
  def bundled, do: @bundled

  # DS-47 (1)
  @doc "The dictionary identifier of a recorded rule id: the part before the first `:`."
  @spec base(String.t()) :: String.t()
  def base(rule_id) when is_binary(rule_id), do: rule_id |> String.split(":", parts: 2) |> hd()

  # DS-47 (1)
  @doc "Returns true when `rule_id` has the recorded form: a dictionary identifier, optionally followed by `:` and a reference, at most 128 characters."
  @spec rule_id?(term()) :: boolean()
  def rule_id?(rule_id) when is_binary(rule_id),
    do:
      byte_size(rule_id) <= 128 and Regex.match?(@rule_id, rule_id) and
        Regex.match?(@id, base(rule_id))

  def rule_id?(_other), do: false

  # DS-47 (3)
  @doc "Indexes the entries of a `rule_dictionary` version by identifier."
  @spec index(map()) :: t()
  def index(%{"rules" => rules}) when is_list(rules), do: Map.new(rules, &{&1["id"], &1})

  # DS-47 (2)
  @doc "Checks the rules of a version that its JSON Schema cannot express: identifiers are unique and of the dictionary form."
  @spec validate(map()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{"rules" => rules}) when is_list(rules) do
    ids = Enum.map(rules, & &1["id"])

    cond do
      length(ids) != length(Enum.uniq(ids)) ->
        invalid("rule identifiers are not unique")

      not Enum.all?(ids, &(is_binary(&1) and Regex.match?(@id, &1))) ->
        invalid("a rule identifier is not of the dictionary form")

      true ->
        :ok
    end
  end

  def validate(_content), do: invalid("not a rule_dictionary version")

  # DS-47 (2)
  @doc "Checks that `next` keeps every rule of `previous`: a rule is deprecated, never removed."
  @spec keeps(map(), map()) :: :ok | {:error, Relay.Error.t()}
  def keeps(previous, next) do
    missing = Map.keys(index(previous)) -- Map.keys(index(next))

    if missing == [],
      do: :ok,
      else: invalid("a rule was removed", %{rules: Enum.sort(missing)})
  end

  # DS-47 (3)
  @doc "Looks up the entry of a recorded rule id in `dictionary`."
  @spec lookup(t(), String.t()) :: {:ok, entry()} | {:error, Relay.Error.t()}
  def lookup(dictionary, rule_id) when is_map(dictionary) and is_binary(rule_id) do
    case Map.fetch(dictionary, base(rule_id)) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, Relay.Error.new(:unknown_rule, "rule not in the dictionary")}
    end
  end

  defp invalid(message, details \\ %{}),
    do: {:error, Relay.Error.new(:invalid_content, message, details)}
end
