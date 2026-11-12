defmodule Relay.Api.CampaignPlanTest do
  use ExUnit.Case, async: true

  alias Relay.Api.Campaigns.Plan

  @t %{bounce_bp: 200, complaint_bp: 5, min_volume: 500}

  defp row(sent, delivered, permanent, complaints) do
    %{
      "channel" => "email",
      "sent" => sent,
      "delivered" => delivered,
      "permanent" => permanent,
      "complaints" => complaints
    }
  end

  describe "WF-62 WF-44 WF-34 OP-37 campaign decisions" do
    test "WF-62: above 100,000 members the audience opens in three stages, PT15M apart" do
      assert Plan.stage_count(100_000) == 1
      assert Plan.stage_count(100_001) == 3
      assert Plan.stage_wait_ms() == 900_000
      assert Plan.sample_count() == 5
    end

    test "WF-62, OP-37: an audience above 1.5 times its expected count needs an approval" do
      refute Plan.audience_approval?(150, 100)
      assert Plan.audience_approval?(151, 100)
    end

    test "WF-34, WF-62: the deadline is after now and at most P31D ahead" do
      now = ~U[2026-11-12 10:00:00Z]
      assert Plan.deadline(DateTime.add(now, 31 * 86_400, :second), now) == :ok
      assert Plan.deadline(DateTime.add(now, 31 * 86_400 + 1, :second), now) == :too_far
      assert Plan.deadline(now, now) == :past
    end

    test "WF-62, CH-37: a permanent failure or complaint rate above its threshold is an alarm, only on the minimum volume" do
      refute Plan.alarm?([row(1_000, 1_000, 20, 0)], @t)
      assert Plan.alarm?([row(1_000, 1_000, 21, 0)], @t)
      assert Plan.alarm?([row(1_000, 1_000, 0, 1)], @t)
      refute Plan.alarm?([row(499, 499, 499, 499)], @t)
      refute Plan.alarm?([], @t)
    end

    test "WF-44: a member identifier is a deterministic UUIDv7 and the dedup key is fixed" do
      campaign = Relay.Id.generate()
      recipient = Relay.Id.generate()
      member = Plan.member_id(campaign, recipient)

      assert Relay.Id.valid?(member)
      assert member == Plan.member_id(campaign, recipient)
      refute member == Plan.member_id(Relay.Id.generate(), recipient)
      assert "cmp:" <> hex = Plan.dedup_key(campaign, recipient)
      assert byte_size(hex) == 48
      assert Plan.dedup_key(campaign, recipient) == Plan.dedup_key(campaign, recipient)
    end

    test "OP-37: a campaign running longer than 1.5 times its estimate is an overrun" do
      start = ~U[2026-11-12 10:00:00Z]
      assert Plan.estimated_duration_s(1_000, 100) == 10
      assert Plan.estimated_duration_s(200_000, 100) == 1_800 + 2_000
      refute Plan.overrun?(start, 100, DateTime.add(start, 150, :second))
      assert Plan.overrun?(start, 100, DateTime.add(start, 151, :second))
      refute Plan.overrun?(nil, 100, start)
    end
  end
end
