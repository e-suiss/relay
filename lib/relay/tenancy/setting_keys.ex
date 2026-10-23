defmodule Relay.Tenancy.SettingKeys do
  @moduledoc """
  The catalog of setting keys (`relay.settings.key`). A setting write names a key from the catalog and a value that passes the key's check; `nil` clears the setting at that level. Stage 1 holds the keys the setting resolver falls back to the tenant defaults for: `default_timezone` and `default_locale`, checked and canonicalised like the tenant defaults (`Relay.Tenancy.Defaults`).
  """

  alias Relay.Tenancy.Defaults

  @catalog %{
    "default_timezone" => :default_timezone,
    "default_locale" => :default_locale
  }

  @doc "Returns the catalog's keys."
  @spec keys() :: [String.t()]
  def keys, do: @catalog |> Map.keys() |> Enum.sort()

  # TN-4
  @doc "Checks a setting write: an unknown key is refused, a value is checked and canonicalised, `nil` clears."
  @spec cast(term(), term()) :: {:ok, term()} | {:error, Relay.Error.t()}
  def cast(key, value) do
    case Map.fetch(@catalog, key) do
      {:ok, _field} when is_nil(value) ->
        {:ok, nil}

      {:ok, field} ->
        Defaults.cast(field, value)

      :error ->
        {:error, Relay.Error.new(:unknown_setting, "not a setting key", %{key: inspect(key)})}
    end
  end
end
