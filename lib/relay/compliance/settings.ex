defmodule Relay.Compliance.Settings do
  @moduledoc """
  Tightening of the compliance table by the installation and by a tenant (PC-40, INV-17): the content of a `compliance_settings` version and its pure rules. A refusal names a country or a region key of the table and the consent kinds that are not accepted there. Only soft opt-in and legitimate interest can be refused, so a setting can make a row stricter and never looser; there is no field that relaxes a row, switches a legal send window off or widens it (PC-47).
  """

  @refusable ["soft_opt_in", "legitimate_interest"]

  @type content :: %{required(String.t()) => term()}
  @type refusals :: %{optional(String.t()) => [String.t()]}

  # INV-17
  @doc "The consent kinds a setting can refuse."
  @spec refusable() :: [String.t(), ...]
  def refusable, do: @refusable

  # PC-40
  @doc "Checks the rules of a `compliance_settings` version that its JSON Schema cannot express: each country appears once."
  @spec validate(content()) :: :ok | {:error, Relay.Error.t()}
  def validate(%{"refusals" => rows}) when is_list(rows) do
    if check(rows) == [] do
      :ok
    else
      {:error,
       Relay.Error.new(:invalid_content, "compliance_settings breaks a consistency rule", %{
         rule: :unique_countries
       })}
    end
  end

  def validate(_content),
    do: {:error, Relay.Error.new(:invalid_content, "not a compliance_settings version")}

  # PC-40
  # INV-17
  @doc "Checks a tenant's refusals: a consent kind that cannot be refused and a country named twice are returned as `{index, field, code}`; empty when the refusals hold."
  @spec check([map()]) :: [{non_neg_integer(), String.t(), String.t()}]
  def check(rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce({MapSet.new(), []}, fn {row, index}, {seen, errors} ->
      country = row["country"]
      errors = kinds(row, index) ++ errors

      if MapSet.member?(seen, country),
        do: {seen, [{index, "country", "conflict"} | errors]},
        else: {MapSet.put(seen, country), errors}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp kinds(row, index) do
    case row["consent_kinds"] do
      kinds when is_list(kinds) ->
        if kinds -- @refusable == [], do: [], else: [{index, "consent_kinds", "not_allowed"}]

      _other ->
        [{index, "consent_kinds", "not_allowed"}]
    end
  end

  # PC-40
  # INV-17
  @doc "The refusals in force from the installation's content and the tenant's (`nil` for none), by country or region key: a kind either of them refuses is refused."
  @spec merge(content() | nil, content() | nil) :: refusals()
  def merge(installation, tenant) do
    for content <- [installation, tenant],
        is_map(content),
        %{"country" => country, "consent_kinds" => kinds} <- Map.get(content, "refusals", []),
        reduce: %{} do
      acc -> Map.update(acc, country, Enum.uniq(kinds), &Enum.uniq(&1 ++ kinds))
    end
  end
end
