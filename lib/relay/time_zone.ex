defmodule Relay.TimeZone do
  @moduledoc """
  IANA time zone identifiers, checked against the tzdata release bundled with the image. A link name is replaced by the zone it links to (`Turkey` and `Asia/Istanbul` become `Europe/Istanbul`), so one zone has one name. Offsets such as `+03:00`, the fixed offset zones `Etc/GMT±N` (and `Etc/GMT` itself), the POSIX rule zones such as `EST5EDT` and the `Factory` placeholder are not accepted.
  """

  @type t :: String.t()

  @name ~r/\A[A-Za-z]+(\/[A-Za-z0-9_+\-]+)*\z/
  @offset ~r/\A(Etc\/GMT|(UTC|GMT)[+\-])/

  # TN-2
  # TN-65 (6)
  # C-57
  # OP-1
  @doc "Validates an IANA time zone identifier against the bundled tzdata and returns its canonical name."
  @spec new(term()) :: {:ok, t()} | {:error, Relay.Error.t()}
  def new(name) when is_binary(name) and byte_size(name) > 0 do
    canonical = Map.get(Tzdata.links(), name, name)

    if Tzdata.canonical_zone?(canonical) and accepted?(canonical),
      do: {:ok, canonical},
      else: invalid()
  end

  def new(_other), do: invalid()

  @doc "Returns true if a canonical zone name is one Relay accepts."
  @spec accepted?(String.t()) :: boolean()
  def accepted?(canonical) when is_binary(canonical),
    do:
      canonical != "Factory" and Regex.match?(@name, canonical) and
        not Regex.match?(@offset, canonical)

  defp invalid, do: {:error, Relay.Error.new(:invalid_time_zone, "not an IANA time zone")}
end
