defmodule Relay.Channels.Whatsapp.Limits do
  @moduledoc """
  The WhatsApp limits as data (CH-61, CH-17), read from the versioned data set `whatsapp_messaging_limits`.

    * The messaging limit tier caps the unique recipients a business portfolio reaches outside a customer service window in a moving 24 hours. Relay counts them exactly, with a membership set, so "was this recipient counted?" has an answer; a recipient already counted in the window does not count again, and a message inside an open window does not count at all. The tenant is warned once the count reaches the warning share of the tier (90 %). While the portfolio's tier is unknown the default tier applies, the lowest.
    * The throughput of a business number, the pair limit of one number and one user and the template management quota of the Graph API are limit data; Relay stays below them and its own buckets slow on `130429` and `131056` (CH-17).
    * During a throughput upgrade a number is unusable for a short time; Relay models it as an event and defers the number's jobs for `upgrade_unavailable_ms` (`unavailable_ms/1`).
  """

  @type tier_limit :: pos_integer() | :unlimited

  # CH-61
  @doc "The recipient limit of a tier name (`TIER_2K`) or of a limit Meta reports as a number; an unknown tier is the default tier's limit."
  @spec tier_limit(map(), String.t() | nil) :: tier_limit()
  def tier_limit(%{"tiers" => tiers, "default_tier" => default}, tier) do
    case find(tiers, tier) || find(tiers, default) do
      %{"limit" => nil} -> :unlimited
      %{"limit" => limit} -> limit
    end
  end

  defp find(_tiers, nil), do: nil

  defp find(tiers, value) do
    Enum.find(tiers, &(&1["tier"] == value)) ||
      case Integer.parse(value) do
        {number, ""} -> Enum.find(tiers, &(&1["limit"] == number))
        _other -> nil
      end
  end

  # CH-61
  @doc "Whether a recipient counts toward the tier: only a message outside an open customer service window does."
  @spec counts?(boolean()) :: boolean()
  def counts?(window_open?) when is_boolean(window_open?), do: not window_open?

  # CH-61
  @doc "Whether adding one recipient that moves the count from `before` to `after` crosses the warning share of the limit; an unlimited tier never warns."
  @spec warn?(map(), non_neg_integer(), non_neg_integer(), tier_limit()) :: boolean()
  def warn?(_limits, _before, _after, :unlimited), do: false

  def warn?(%{"warn_bp" => bp}, before, after_count, limit) when is_integer(limit) do
    threshold = div(limit * bp + 9_999, 10_000)
    before < threshold and after_count >= threshold
  end

  @doc "The moving window of the tier count, in milliseconds."
  @spec window_ms(map()) :: pos_integer()
  def window_ms(%{"window_ms" => ms}), do: ms

  # CH-61
  @doc "How long a number's jobs are deferred during a throughput upgrade."
  @spec unavailable_ms(map()) :: pos_integer()
  def unavailable_ms(%{"upgrade_unavailable_ms" => ms}), do: ms

  @doc "The edit limits of an approved template (TP-23)."
  @spec template_edits(map()) :: map()
  def template_edits(%{"template_edits" => edits}), do: edits
end
