defmodule Relay.Compliance do
  @moduledoc """
  The compliance table and its rules (PC-40, MD-17): what consent a delivery needs for its country, channel, message class and legal recipient type, the platform rows, the derived `marketing` default, the legal send window and the scope of a revocation. Everything here is a pure function of the content of the `compliance_table` and `compliance_settings` data sets; nothing is read or written. Other contexts use only the functions of this module.

  The country of a recipient comes from the profile country and from the country calling code of the phone number; when they differ, the more restrictive row decides. A recipient without either is read with the country of the tenant's region.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.Compliance.Settings
  alias Relay.Compliance.Table

  @regions %{"tr" => "TR", "eu" => "EU", "us" => "US"}

  @type table :: Table.content()
  @type query :: Table.query()
  @type resolution :: Table.resolution()

  # PC-44
  @doc "The number and content of the `compliance_table` version bundled with the release."
  @spec bundled_table() :: {pos_integer(), table()}
  def bundled_table, do: Table.bundled()

  # PC-40
  # PC-44
  @doc "Checks the consistency rules of a `compliance_table` version; see `Relay.Compliance.Table.validate/1`."
  @spec validate_table(map()) :: :ok | {:error, Relay.Error.t()}
  def validate_table(content), do: Table.validate(content)

  # PC-40
  @doc "Checks the consistency rules of a `compliance_settings` version; see `Relay.Compliance.Settings.validate/1`."
  @spec validate_settings(map()) :: :ok | {:error, Relay.Error.t()}
  def validate_settings(content), do: Settings.validate(content)

  # INV-17
  @doc "Checks a tenant's refusals; see `Relay.Compliance.Settings.check/1`."
  @spec check_refusals([map()]) :: [{non_neg_integer(), String.t(), String.t()}]
  def check_refusals(rows), do: Settings.check(rows)

  # INV-17
  @doc "The refusals in force from the installation's and the tenant's `compliance_settings` content; see `Relay.Compliance.Settings.merge/2`."
  @spec refusals(map() | nil, map() | nil) :: Settings.refusals()
  def refusals(installation, tenant), do: Settings.merge(installation, tenant)

  # PC-40
  @doc "The country a region's tenants are read with when a recipient has no country: the region's own row key."
  @spec region_country(String.t()) :: String.t()
  def region_country(region), do: Map.fetch!(@regions, region)

  # PC-40
  # PC-47
  @doc "The countries a recipient may be in, from the phone number's country calling code and the profile country; see `Relay.Compliance.Table.candidates/3`."
  @spec candidates(table(), String.t() | nil, String.t() | nil) :: [String.t()]
  def candidates(table, calling_code, profile_country),
    do: Table.candidates(table, calling_code, profile_country)

  # PC-40
  # PC-41
  # PC-54
  # INV-17
  @doc "Resolves what a delivery needs from the table and the refusals in force; see `Relay.Compliance.Table.resolve/3`."
  @spec resolve(table(), Settings.refusals(), query()) :: resolution()
  def resolve(table, refusals, query), do: Table.resolve(table, refusals, query)

  # PC-39
  # PC-61
  @doc "The scope of a revocation received in `country` on `channel`; see `Relay.Compliance.Table.revocation_scope/3`."
  @spec revocation_scope(table(), String.t(), String.t()) ::
          %{scope: String.t(), channels: [String.t()]} | nil
  def revocation_scope(table, country, channel),
    do: Table.revocation_scope(table, country, channel)

  # TP-33
  @doc "The footer fields a commercial message to `country` on `channel` must carry; see `Relay.Compliance.Table.footer/3`."
  @spec footer(table(), String.t(), String.t()) :: [String.t()]
  def footer(table, country, channel), do: Table.footer(table, country, channel)
end
