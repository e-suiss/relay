defmodule Relay.Policy.Fixture do
  @moduledoc "Snapshots for the policy lattice tests: a sendable `transactional` email at noon UTC on Monday 2 November 2026 (15:00 in Istanbul), which each test changes."

  alias Relay.Policy.Snapshot

  @nested [:notification, :category, :preferences, :profile, :target]

  @doc "The fixed tenant id of the fixture."
  @spec tenant_id() :: Relay.Id.t()
  def tenant_id, do: Relay.Id.build(1_790_000_000_000, <<1::80>>)

  @doc "The fixed recipient id of the fixture."
  @spec recipient_id() :: Relay.Id.t()
  def recipient_id, do: Relay.Id.build(1_790_000_000_000, <<2::80>>)

  @doc "The fixed delivery id of the fixture."
  @spec delivery_id() :: Relay.Id.t()
  def delivery_id, do: Relay.Id.build(1_790_000_000_000, <<3::80>>)

  @doc "The fixture's `now`."
  @spec now() :: DateTime.t()
  def now, do: ~U[2026-11-02 12:00:00Z]

  @doc "A zero frequency reading."
  @spec zero() :: Snapshot.reading()
  def zero, do: %{count: 0, free_at: nil}

  @doc "Builds a snapshot from the base; a keyword list or map under a nested field is merged into it, any other value replaces the field."
  @spec snapshot(keyword()) :: Snapshot.t()
  def snapshot(changes \\ []) do
    changes
    |> Enum.reduce(base(), fn
      {field, value}, acc when field in @nested and (is_list(value) or is_map(value)) ->
        Map.update!(acc, field, &Map.merge(&1, Map.new(value)))

      {field, value}, acc ->
        Map.put(acc, field, value)
    end)
    |> Snapshot.new!()
  end

  defp base do
    %{
      now: now(),
      tenant_id: tenant_id(),
      environment: :live,
      recipient_id: recipient_id(),
      delivery_id: delivery_id(),
      channel: :email,
      target: %{address: :present, permission: :unknown, platform: nil},
      notification: %{
        message_class: :transactional,
        security_subtype: nil,
        priority: nil,
        expires_at: DateTime.add(now(), 1, :day),
        on_expire: :drop,
        workflow_key: "order-shipped",
        scope_key: nil,
        sender_kind: :system,
        scope: :match
      },
      category: %{
        key: "orders",
        locked: false,
        enabled: true,
        channel_defaults: %{},
        frequency: nil,
        digest_allowed: false,
        subtenant_override: false
      },
      preferences: %{
        category_channel: :unset,
        channel: :unset,
        workflow: :unset,
        scope_key: :unset
      },
      profile: %{
        time_zone: "Europe/Istanbul",
        quiet_hours: [],
        schedule: nil,
        dnd_until: nil,
        email_in_quiet_hours: false,
        digest: nil
      },
      consent: %{state: :none, ref: nil},
      suppression: nil,
      kill_switch: :allow,
      tenant_suspended: false,
      tenant_time_zone: "Europe/Istanbul",
      device_time_zone: nil,
      profile_country: nil,
      country_time_zones: nil,
      frequency: %{global: zero(), policy: zero()},
      global_cap: nil,
      jitter_spread_ms: 0
    }
  end
end
