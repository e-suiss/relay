defmodule Relay.Api.Campaigns.Plan do
  @moduledoc """
  The pure decisions of a campaign (API-35, WF-34, WF-44, WF-62, OP-37):

    * A member's identifier is a UUIDv7 built from the SHA-256 of the campaign and the recipient, so the audience is ordered by a deterministic hash, a recipient listed twice is one member, and the first members in identifier order are a deterministic spread of the audience: they are the five render samples and the first ramp stages.
    * A member's `dedup_key` is fixed when the member is added, before preparation freezes the audience.
    * The deadline is required and at most P31D after the request.
    * A frozen audience above 1.5 times the declared `expected_count` needs a tenant administrator's approval before the trigger.
    * An audience above 100,000 opens in stages of 1 %, 10 % and 100 %, PT15M apart.
    * A channel whose permanent failure rate over sent deliveries or complaint rate over delivered deliveries is above its alarm threshold, on at least the minimum volume, pauses the campaign.
    * A campaign running longer than 1.5 times its estimate is an overrun.
  """

  @max_deadline_ms 31 * 24 * 3_600_000
  @ramp_threshold 100_000
  @stage_wait_ms 15 * 60_000
  @samples 5

  @type rates :: %{required(String.t()) => term()}
  @type thresholds :: %{
          bounce_bp: pos_integer(),
          complaint_bp: pos_integer(),
          min_volume: non_neg_integer()
        }

  # WF-62
  @doc "The number of deterministic render samples."
  @spec sample_count() :: pos_integer()
  def sample_count, do: @samples

  # WF-62
  @doc "The wait between two ramp stages, in milliseconds."
  @spec stage_wait_ms() :: pos_integer()
  def stage_wait_ms, do: @stage_wait_ms

  # WF-44
  @doc "The identifier of a recipient's member in a campaign."
  @spec member_id(Relay.Id.t(), Relay.Id.t()) :: Relay.Id.t()
  def member_id(<<_::128>> = campaign_id, <<_::128>> = recipient_id) do
    <<ms::48, rand::binary-10, _rest::binary>> =
      :crypto.hash(:sha256, ["campaign_member", campaign_id, recipient_id])

    Relay.Id.build(ms, rand)
  end

  # WF-44
  # WF-36
  @doc "The `dedup_key` of a recipient's notification in a campaign."
  @spec dedup_key(Relay.Id.t(), Relay.Id.t()) :: String.t()
  def dedup_key(campaign_id, recipient_id) do
    digest = :crypto.hash(:sha256, ["campaign_dedup", campaign_id, recipient_id])
    "cmp:" <> Base.encode16(binary_part(digest, 0, 24), case: :lower)
  end

  # WF-34
  # WF-62
  @doc "Checks a deadline against the current business time: after it and at most P31D ahead."
  @spec deadline(DateTime.t(), DateTime.t()) :: :ok | :past | :too_far
  def deadline(%DateTime{} = deadline, %DateTime{} = now) do
    ms = DateTime.diff(deadline, now, :millisecond)

    cond do
      ms <= 0 -> :past
      ms > @max_deadline_ms -> :too_far
      true -> :ok
    end
  end

  # WF-62
  # OP-37
  @doc "True when a frozen audience is above 1.5 times its expected count."
  @spec audience_approval?(non_neg_integer(), pos_integer()) :: boolean()
  def audience_approval?(audience, expected), do: audience * 2 > expected * 3

  # WF-62
  @doc "The number of ramp stages of an audience: three above 100,000 members, otherwise one."
  @spec stage_count(non_neg_integer()) :: 1 | 3
  def stage_count(audience) when audience > @ramp_threshold, do: 3
  def stage_count(_audience), do: 1

  # WF-62
  # CH-37
  @doc "True when one channel's permanent failure or complaint rate is above its threshold on at least the minimum volume of sent deliveries."
  @spec alarm?([rates()], thresholds()) :: boolean()
  def alarm?(rates, thresholds), do: Enum.any?(rates, &channel_alarm?(&1, thresholds))

  defp channel_alarm?(%{"sent" => sent} = row, t) do
    delivered = row["delivered"]
    permanent = row["permanent"] * 10_000 > t.bounce_bp * sent
    complaints = delivered > 0 and row["complaints"] * 10_000 > t.complaint_bp * delivered
    sent > 0 and sent >= t.min_volume and (permanent or complaints)
  end

  # OP-37
  @doc "The duration estimate of a campaign in seconds: the ramp waits and the audience at an assumed throughput."
  @spec estimated_duration_s(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def estimated_duration_s(audience, per_second) when per_second > 0 do
    waits = (stage_count(audience) - 1) * div(@stage_wait_ms, 1000)
    waits + div(audience + per_second - 1, per_second)
  end

  # OP-37
  @doc "True when a campaign triggered at `triggered_at` runs longer than 1.5 times its estimate at `now`."
  @spec overrun?(DateTime.t() | nil, non_neg_integer() | nil, DateTime.t()) :: boolean()
  def overrun?(%DateTime{} = triggered_at, estimate_s, %DateTime{} = now)
      when is_integer(estimate_s) do
    DateTime.diff(now, triggered_at, :second) * 2 > estimate_s * 3
  end

  def overrun?(_triggered_at, _estimate_s, _now), do: false
end
