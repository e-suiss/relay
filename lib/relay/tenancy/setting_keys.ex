defmodule Relay.Tenancy.SettingKeys do
  @moduledoc """
  The catalog of setting keys (`relay.settings.key`). A setting write names a key from the catalog and a value that passes the key's check; `nil` clears the setting at that level. Stage 1 holds the keys the setting resolver falls back to the tenant defaults for: `default_timezone` and `default_locale`, checked and canonicalised like the tenant defaults (`Relay.Tenancy.Defaults`). `fairness.weight.l2` and `fairness.weight.l3` hold the tenant's DRR weight in a bulk lane, an integer from 1 to 100 (1 when unset); only the tenant-level value counts. `api.rate.burst` and `api.rate.sustained` hold the tenant's API rate limit tiers (API-50, API-77), an object with a positive integer `weight` and a positive integer `window_seconds` of at most 3600; an unset tier takes the contract default. `api.mtls_required` (`true` or `false`) makes the tenant's server API accept only certificate-bound tokens (RFC 8705; API-41, API-48). `send_mode`, `send_mode.channel.<channel>` and `send_mode.category.<category>.channel.<channel>` hold the tenant's send modes (OP-51): `live`, `shadow`, `dry_run` or `off`.
  """

  alias Relay.Tenancy.Defaults

  @catalog %{
    "default_timezone" => :default_timezone,
    "default_locale" => :default_locale,
    "fairness.weight.l2" => :fairness_weight,
    "fairness.weight.l3" => :fairness_weight,
    "api.rate.burst" => :api_rate,
    "api.rate.sustained" => :api_rate,
    "api.mtls_required" => :boolean
  }

  @send_modes ~w(live shadow dry_run off)
  @send_mode ~r/\Asend_mode(\.channel\.[a-z_]+|\.category\.[a-z][a-z0-9_]{0,63}\.channel\.[a-z_]+)?\z/

  @doc "Returns the catalog's keys."
  @spec keys() :: [String.t()]
  def keys, do: @catalog |> Map.keys() |> Enum.sort()

  # TN-4
  # T-21 (2)
  @doc "Checks a setting write: an unknown key is refused, a value is checked and canonicalised, `nil` clears."
  @spec cast(term(), term()) :: {:ok, term()} | {:error, Relay.Error.t()}
  def cast(key, value) do
    case Map.fetch(@catalog, key) do
      :error when is_binary(key) -> send_mode(key, value)
      found -> catalog(found, key, value)
    end
  end

  # OP-51
  defp send_mode(key, value) do
    cond do
      not Regex.match?(@send_mode, key) ->
        {:error, Relay.Error.new(:unknown_setting, "not a setting key", %{key: inspect(key)})}

      value == nil or value in @send_modes ->
        {:ok, value}

      true ->
        {:error, Relay.Error.new(:invalid_setting, "a send mode is live, shadow, dry_run or off")}
    end
  end

  defp catalog(found, key, value) do
    case found do
      {:ok, _field} when is_nil(value) ->
        {:ok, nil}

      {:ok, :fairness_weight} when is_integer(value) and value >= 1 and value <= 100 ->
        {:ok, value}

      {:ok, :fairness_weight} ->
        {:error,
         Relay.Error.new(:invalid_setting, "a fairness weight is an integer from 1 to 100")}

      {:ok, kind} when kind in [:api_rate, :boolean] ->
        check(kind, value)

      {:ok, field} ->
        Defaults.cast(field, value)

      :error ->
        {:error, Relay.Error.new(:unknown_setting, "not a setting key", %{key: inspect(key)})}
    end
  end

  defp check(:api_rate, value), do: api_rate(value)

  # API-41
  defp check(:boolean, value) when is_boolean(value), do: {:ok, value}

  defp check(:boolean, _value),
    do: {:error, Relay.Error.new(:invalid_setting, "the setting is true or false")}

  # API-50
  # API-77 (4)
  defp api_rate(%{"weight" => weight, "window_seconds" => window} = value)
       when map_size(value) == 2 and is_integer(weight) and weight > 0 and weight <= 1_000_000 and
              is_integer(window) and window > 0 and window <= 3_600,
       do: {:ok, value}

  defp api_rate(_value),
    do:
      {:error,
       Relay.Error.new(
         :invalid_setting,
         "an API rate tier is an object with a positive weight and window_seconds"
       )}
end
