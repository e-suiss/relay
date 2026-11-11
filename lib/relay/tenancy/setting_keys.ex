defmodule Relay.Tenancy.SettingKeys do
  @moduledoc """
  The catalog of setting keys (`relay.settings.key`). A setting write names a key from the catalog and a value that passes the key's check; `nil` clears the setting at that level. Stage 1 holds the keys the setting resolver falls back to the tenant defaults for: `default_timezone` and `default_locale`, checked and canonicalised like the tenant defaults (`Relay.Tenancy.Defaults`). `fairness.weight.l2` and `fairness.weight.l3` hold the tenant's DRR weight in a bulk lane, an integer from 1 to 100 (1 when unset); only the tenant-level value counts. `api.rate.burst` and `api.rate.sustained` hold the tenant's API rate limit tiers (API-50, API-77), an object with a positive integer `weight` and a positive integer `window_seconds` of at most 3600; an unset tier takes the contract default. `api.mtls_required` (`true` or `false`) makes the tenant's server API accept only certificate-bound tokens (RFC 8705; API-41, API-48). `devices.max_active` lowers the subscriber's active device limit (CH-74): an integer from 1 to the contract's `devices.max_active_per_subscriber`; a tenant can never raise it. `send_mode`, `send_mode.channel.<channel>`, `send_mode.category.<category>.channel.<channel>` and `send_mode.workflow.<workflow>` hold the tenant's send modes (OP-51, C-89): `live`, `shadow`, `dry_run` or `off`. `channels.domestic_only` turns on the tenant's domestic-only policy (CH-6, TN-58): an ISO 3166-1 alpha-2 country code, and a provider account processing data outside that country is listed but never routed. `overrides.<channel>.provider` is the tenant default of the provider a channel is narrowed to (API-23), the last level after the request, the step and the workflow: a provider name. `email.tracking.category.<category>` and `email.tracking.template.t_<template>` (the template key's hyphens as underscores) turn on e-mail open and click tracking for a category or a template (CH-43, DS-29): an object of the booleans `open_pixel` and `wrap_links`. The `brand.*` keys hold the brand fields templates render (TP-35, TP-48): `brand.logo_url` (an `https` URL of at most 2048 characters), `brand.primary_color` and `brand.secondary_color` (`#RRGGBB`), `brand.sender_name` (at most 100 characters), `brand.footer` (at most 2000), `brand.legal_name` (at most 200), `brand.mersis` (16 digits), `brand.contact` and `brand.postal_address` (at most 500); a sub-tenant inherits every brand field it does not set (TP-36).
  """

  alias Relay.Tenancy.Defaults

  @catalog %{
    "default_timezone" => :default_timezone,
    "default_locale" => :default_locale,
    "fairness.weight.l2" => :fairness_weight,
    "fairness.weight.l3" => :fairness_weight,
    "api.rate.burst" => :api_rate,
    "api.rate.sustained" => :api_rate,
    "api.mtls_required" => :boolean,
    "devices.max_active" => :device_limit,
    "channels.domestic_only" => :country,
    "brand.logo_url" => {:brand, :url, 2048},
    "brand.primary_color" => {:brand, :color, 7},
    "brand.secondary_color" => {:brand, :color, 7},
    "brand.sender_name" => {:brand, :text, 100},
    "brand.footer" => {:brand, :text, 2000},
    "brand.legal_name" => {:brand, :text, 200},
    "brand.mersis" => {:brand, :mersis, 16},
    "brand.contact" => {:brand, :text, 500},
    "brand.postal_address" => {:brand, :text, 500}
  }

  @device_limit Relay.Limits.fetch!(["devices", "max_active_per_subscriber"])
  @send_modes ~w(live shadow dry_run off)
  @provider_override ~r/\Aoverrides\.[a-z_]+\.provider\z/
  @provider ~r/\A[a-z][a-z0-9_]{1,31}\z/
  @tracking ~r/\Aemail\.tracking\.(category\.[a-z][a-z0-9_]{0,63}|template\.t_[a-z0-9_]{1,100})\z/
  @send_mode ~r/\Asend_mode(\.channel\.[a-z_]+|\.category\.[a-z][a-z0-9_]{0,63}\.channel\.[a-z_]+|\.workflow\.[a-z0-9]+(-[a-z0-9]+)*)?\z/

  @doc "Returns the catalog's keys."
  @spec keys() :: [String.t()]
  def keys, do: @catalog |> Map.keys() |> Enum.sort()

  # TN-4
  # T-21 (2)
  @doc "Checks a setting write: an unknown key is refused, a value is checked and canonicalised, `nil` clears."
  @spec cast(term(), term()) :: {:ok, term()} | {:error, Relay.Error.t()}
  def cast(key, value) do
    case Map.fetch(@catalog, key) do
      {:ok, {:brand, kind, max}} when not is_nil(value) -> brand(kind, max, value)
      :error when is_binary(key) -> pattern(key, value)
      found -> catalog(found, key, value)
    end
  end

  # API-23
  # DS-29
  defp pattern(key, value) do
    cond do
      Regex.match?(@provider_override, key) -> provider(value)
      Regex.match?(@tracking, key) -> tracking(value)
      true -> send_mode(key, value)
    end
  end

  # CH-43
  # DS-29
  defp tracking(nil), do: {:ok, nil}

  defp tracking(%{"open_pixel" => open, "wrap_links" => wrap} = value)
       when is_boolean(open) and is_boolean(wrap) and map_size(value) == 2,
       do: {:ok, value}

  defp tracking(_value) do
    message = "e-mail tracking is an object of the booleans open_pixel and wrap_links"
    {:error, Relay.Error.new(:invalid_setting, message)}
  end

  defp provider(value) do
    if value == nil or (is_binary(value) and Regex.match?(@provider, value)),
      do: {:ok, value},
      else: {:error, Relay.Error.new(:invalid_setting, "a provider is a provider name")}
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

      {:ok, kind} when kind in [:api_rate, :boolean, :device_limit, :country] ->
        check(kind, value)

      {:ok, field} ->
        Defaults.cast(field, value)

      :error ->
        {:error, Relay.Error.new(:unknown_setting, "not a setting key", %{key: inspect(key)})}
    end
  end

  defp check(:api_rate, value), do: api_rate(value)

  # CH-74
  defp check(:device_limit, value) when is_integer(value) and value in 1..@device_limit//1,
    do: {:ok, value}

  defp check(:device_limit, _value) do
    message = "the device limit is an integer from 1 to #{@device_limit}"
    {:error, Relay.Error.new(:invalid_setting, message)}
  end

  # CH-6
  # TN-58
  defp check(:country, value) do
    if is_binary(value) and Regex.match?(~r/\A[A-Z]{2}\z/, value),
      do: {:ok, value},
      else: {:error, Relay.Error.new(:invalid_setting, "a country is an ISO 3166-1 alpha-2 code")}
  end

  # API-41
  defp check(:boolean, value) when is_boolean(value), do: {:ok, value}

  defp check(:boolean, _value),
    do: {:error, Relay.Error.new(:invalid_setting, "the setting is true or false")}

  # TP-35
  # TP-48
  defp brand(kind, max, value) when is_binary(value) do
    if String.valid?(value) and String.length(value) in 1..max and brand?(kind, value),
      do: {:ok, value},
      else: brand_error(kind)
  end

  defp brand(kind, _max, _value), do: brand_error(kind)

  defp brand?(:url, value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _other -> false
    end
  end

  defp brand?(:color, value), do: Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, value)
  defp brand?(:mersis, value), do: Regex.match?(~r/\A[0-9]{16}\z/, value)
  defp brand?(:text, value), do: not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, value)

  defp brand_error(kind) do
    message =
      case kind do
        :url -> "a brand URL is an https URL"
        :color -> "a brand color is #RRGGBB"
        :mersis -> "a MERSIS number is 16 digits"
        :text -> "a brand text is a non-empty string within its length"
      end

    {:error, Relay.Error.new(:invalid_setting, message)}
  end

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
