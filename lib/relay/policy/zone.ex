defmodule Relay.Policy.Zone do
  @moduledoc """
  The recipient's time zone and the local time arithmetic of the lattice (WF-45, WF-47, PC-58 (4)). The chain is: the explicit zone of the recipient's profile, then the zone the device reported, then the profile country when that country has a single IANA zone, then the tenant's `default_timezone`. A candidate that is not an accepted IANA zone is passed over. All local time is computed here with the bundled tzdata; nothing is stored in local time.
  """

  @type source :: :profile | :device | :country | :tenant_default

  # WF-45
  # PC-58 (4)
  @doc "Resolves the zone and its source; `:error` when not even the tenant default is a valid zone."
  @spec resolve(String.t() | nil, String.t() | nil, [String.t()] | nil, String.t() | nil) ::
          {:ok, {Relay.TimeZone.t(), source()}} | :error
  def resolve(profile_zone, device_zone, country_zones, tenant_zone) do
    [
      {profile_zone, :profile},
      {device_zone, :device},
      {single(country_zones), :country},
      {tenant_zone, :tenant_default}
    ]
    |> Enum.find_value(:error, fn {name, source} ->
      case Relay.TimeZone.new(name) do
        {:ok, zone} -> {:ok, {zone, source}}
        {:error, _} -> nil
      end
    end)
  end

  defp single(zones) when is_list(zones) do
    case zones |> Enum.flat_map(&canonical/1) |> Enum.uniq() do
      [zone] -> zone
      _none_or_many -> nil
    end
  end

  defp single(_none), do: nil

  defp canonical(name) do
    case Relay.TimeZone.new(name) do
      {:ok, zone} -> [zone]
      {:error, _} -> []
    end
  end

  # WF-47
  @doc "The wall-clock time of a UTC instant in a zone."
  @spec local(DateTime.t(), Relay.TimeZone.t()) :: NaiveDateTime.t()
  def local(%DateTime{} = at, zone), do: at |> DateTime.shift_zone!(zone) |> DateTime.to_naive()

  @doc "The total UTC offset of a zone at a UTC instant, in seconds."
  @spec offset(DateTime.t(), Relay.TimeZone.t()) :: integer()
  def offset(%DateTime{} = at, zone) do
    shifted = DateTime.shift_zone!(at, zone)
    shifted.utc_offset + shifted.std_offset
  end
end
