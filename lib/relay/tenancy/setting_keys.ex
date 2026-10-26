defmodule Relay.Tenancy.SettingKeys do
  @moduledoc """
  The catalog of setting keys (`relay.settings.key`). A setting write names a key from the catalog and a value that passes the key's check; `nil` clears the setting at that level. Stage 1 holds the keys the setting resolver falls back to the tenant defaults for: `default_timezone` and `default_locale`, checked and canonicalised like the tenant defaults (`Relay.Tenancy.Defaults`). `fairness.weight.l2` and `fairness.weight.l3` hold the tenant's DRR weight in a bulk lane, an integer from 1 to 100 (1 when unset); only the tenant-level value counts.
  """

  alias Relay.Tenancy.Defaults

  @catalog %{
    "default_timezone" => :default_timezone,
    "default_locale" => :default_locale,
    "fairness.weight.l2" => :fairness_weight,
    "fairness.weight.l3" => :fairness_weight
  }

  @doc "Returns the catalog's keys."
  @spec keys() :: [String.t()]
  def keys, do: @catalog |> Map.keys() |> Enum.sort()

  # TN-4
  # T-21 (2)
  @doc "Checks a setting write: an unknown key is refused, a value is checked and canonicalised, `nil` clears."
  @spec cast(term(), term()) :: {:ok, term()} | {:error, Relay.Error.t()}
  def cast(key, value) do
    case Map.fetch(@catalog, key) do
      {:ok, _field} when is_nil(value) ->
        {:ok, nil}

      {:ok, :fairness_weight} when is_integer(value) and value >= 1 and value <= 100 ->
        {:ok, value}

      {:ok, :fairness_weight} ->
        {:error,
         Relay.Error.new(:invalid_setting, "a fairness weight is an integer from 1 to 100")}

      {:ok, field} ->
        Defaults.cast(field, value)

      :error ->
        {:error, Relay.Error.new(:unknown_setting, "not a setting key", %{key: inspect(key)})}
    end
  end
end
