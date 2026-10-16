defmodule Relay.TimeZone do
  @moduledoc """
  IANA time zone identifiers, checked against the tzdata release bundled with the image. Offsets such as `+03:00` are not time zone identifiers.
  """

  @type t :: String.t()

  # TN-2
  # C-57
  # OP-1
  @doc "Validates an IANA time zone identifier against the bundled tzdata."
  @spec new(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(name) when is_binary(name) and byte_size(name) > 0 do
    if Tzdata.zone_exists?(name),
      do: {:ok, name},
      else: invalid()
  end

  def new(_other), do: invalid()

  defp invalid, do: {:error, Relay.Error.new(:invalid_time_zone, "not an IANA time zone")}
end
