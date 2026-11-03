defmodule Relay.Templates.Sms.Segments do
  @moduledoc """
  Conservative, provider-independent SMS segment math (TP-18, CH-48). A single message holds 160 septets in `:gsm7`, 155 in `:gsm7_tr` (the single shift header) and 70 units in `:ucs2`; a concatenated message holds 153, 149 and 67 per segment. The limits are the values of CH-48, which takes the smaller value where providers differ.

  Units are packed greedily and a two-unit character (a GSM escape pair or a UTF-16 surrogate pair) never straddles two segments, so a segment may end one unit short. Reserved units (the operator prefix of a TR SMS with a sender header, CH-48) are counted before the text.
  """

  alias Relay.Templates.Sms.Encoding

  @limits %{gsm7: {160, 153}, gsm7_tr: {155, 149}, ucs2: {70, 67}}

  # CH-48
  @doc "The `{single, per_segment}` unit limits of an encoding."
  @spec limits(Encoding.t()) :: {pos_integer(), pos_integer()}
  def limits(encoding), do: Map.fetch!(@limits, encoding)

  # TP-18
  # CH-48
  @doc "The number of segments that `units`, after `reserved` one-unit places, take in `encoding`; no units take no segment."
  @spec count([1 | 2], Encoding.t(), non_neg_integer()) :: non_neg_integer()
  def count(units, encoding, reserved \\ 0)
  def count([], _encoding, _reserved), do: 0

  def count(units, encoding, reserved) do
    {single, per_segment} = limits(encoding)

    if Enum.sum(units) + reserved <= single,
      do: 1,
      else: pack(List.duplicate(1, reserved) ++ units, per_segment)
  end

  # TP-19
  # CH-48
  @doc "The units a message of `segments` segments holds in `encoding`, after `reserved` units."
  @spec capacity(Encoding.t(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  def capacity(encoding, segments, reserved \\ 0) do
    {single, per_segment} = limits(encoding)
    total = if segments == 1, do: single, else: segments * per_segment
    max(total - reserved, 0)
  end

  defp pack(units, per_segment) do
    units
    |> Enum.reduce({1, 0}, fn unit, {segments, used} ->
      if used + unit > per_segment, do: {segments + 1, unit}, else: {segments, used + unit}
    end)
    |> elem(0)
  end
end
