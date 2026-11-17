defmodule Relay.Policy.Fixture do
  @moduledoc "Snapshots for the policy lattice tests: a sendable `transactional` email at noon UTC on Monday 2 November 2026 (15:00 in Istanbul), which each test changes. Unless a test gives the `compliance` input, it is what the compliance table asks of an individual recipient of a tenant of the Turkey region: `marketing` on email, SMS and voice needs explicit opt-in and its cell is locked off, as are `marketing` on WhatsApp and on iOS push; nothing else needs consent. The tenant is outside İYS."

  alias Relay.Policy.Snapshot

  @nested [:notification, :category, :preferences, :profile, :target, :consent]
  @kinds [:none, :legitimate_interest, :soft_opt_in, :explicit_opt_in]
  @consent_channels [:email, :sms, :voice]

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
    |> then(&Map.put_new_lazy(&1, :compliance, fn -> default_compliance(&1) end))
    |> Snapshot.new!()
  end

  @doc "A compliance input: no consent needed and the cell's default left to the tenant, with `changes` merged in."
  @spec compliance(keyword()) :: Snapshot.compliance()
  def compliance(changes \\ []) do
    Map.merge(
      %{
        required: :none,
        accepted: @kinds,
        recipient_type: :individual,
        default: :tenant,
        legal_windows: [],
        detail: %{}
      },
      Map.new(changes)
    )
  end

  defp default_compliance(%{notification: %{message_class: :marketing}} = fields) do
    cond do
      fields.channel in @consent_channels ->
        compliance(
          required: :explicit_opt_in,
          accepted: [:explicit_opt_in],
          default: :locked_off,
          detail: %{compliance_row: "tr.marketing.individual", compliance_country: "TR"}
        )

      fields.channel == :whatsapp or match?(%{platform: :ios}, fields.target) ->
        compliance(default: :locked_off)

      true ->
        compliance()
    end
  end

  defp default_compliance(_fields), do: compliance()

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
        timing_precision: :jittered,
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
      consent: %{state: :none, ref: nil, kind: :explicit_opt_in},
      iys: :out_of_scope,
      iys_stale_after_ms: 86_400_000,
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
