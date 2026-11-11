defmodule Relay.Policy.Snapshot do
  @moduledoc """
  Everything one evaluation of the policy lattice needs, read once before it runs (PC-58 (1)). The lattice reads nothing else. An input that could not be read is the atom `:unreadable`; a gate input that is unreadable stops the evaluation without a decision (INV-43), and only the frequency counter may be `:unavailable` and is then skipped (INV-45).

  * `now`: the business time of the evaluation.
  * `tenant_id`, `environment`, `recipient_id`, `delivery_id`: identifiers for the jitter digest and the counters.
  * `channel`: the delivery's channel.
  * `target`: the channel target: `address` (`:present`, `:absent`, `:disabled`), the device's OS notification `permission` (`:granted`, `:denied`, `:unknown`) and the device `platform` (`:ios`, `:android`, `:web` or `nil`).
  * `notification`: `message_class`, `security_subtype` (`:otp_oob`, `:email_verification` or `nil`), the requested `priority` (`nil` for none), `expires_at` (`nil` for none), `on_expire` (`:drop` or `:inbox_only`, WF-39), `timing_precision` (`:jittered` or `:strict`, WF-58), `workflow_key`, `scope_key`, `sender_kind` and `scope`, the sub-tenant match (`:match`, `:mismatch` or `:unreadable`).
  * `category`: the category with the sub-tenant settings already applied (PC-57 (2)): `key`, `locked`, `enabled`, `channel_defaults` (channel → `:on | :off`), `frequency` (`nil` or `limit`, `window_ms` and `fate`, each may be `nil`), `digest_allowed` and `subtenant_override` (true when a sub-tenant setting was applied).
  * `preferences`: the recipient's values for this delivery at each level: `category_channel`, `channel`, `workflow` and `scope_key`, each `:opt_in`, `:opt_out` or `:unset`.
  * `profile`: the recipient's preference profile: `time_zone` (`nil` for none), `quiet_hours` (ranges), `schedule` (ranges of availability, `nil` for none), `dnd_until` (`nil` for none), `email_in_quiet_hours` and `digest`.
  * `consent`: the current consent state for the delivery's brand and channel (PC-59 (1)): `state` and `ref`.
  * `suppression`: `nil`, or the suppression hit with its `reason` and `ref`.
  * `kill_switch`: the kill switch decision: `:allow`, `{:pause, kill_switch_id, rule_id}` or `{:hold, rule_id}` (state unknown).
  * `tenant_suspended`: whether the tenant or sub-tenant is suspended.
  * `tenant_time_zone`: the tenant's `default_timezone`.
  * `device_time_zone`: the zone the device reported, or `nil`.
  * `profile_country`: the profile country, or `nil`; `country_time_zones` the zones of that country from the `country_time_zones` dataset, or `nil`.
  * `frequency`: the counter readings (`global` and `policy`, each `nil` when not read) or `:unavailable`.
  * `global_cap`: the tenant's global frequency cap, or `nil` for the platform cap.
  * `jitter_spread_ms`: the spread of the release jitter of deferred deliveries (WF-42).

  A range is `%{days: [1..7], from: Time.t(), to: Time.t()}` in the recipient's local time: ISO weekdays (1 is Monday) on which the range starts, a start and an end; an end at or before the start is on the next day.
  """

  @enforce_keys [
    :now,
    :tenant_id,
    :environment,
    :recipient_id,
    :delivery_id,
    :channel,
    :target,
    :notification,
    :category,
    :preferences,
    :profile,
    :consent,
    :suppression,
    :kill_switch,
    :tenant_suspended,
    :tenant_time_zone,
    :device_time_zone,
    :profile_country,
    :country_time_zones,
    :frequency,
    :global_cap,
    :jitter_spread_ms
  ]
  defstruct @enforce_keys

  @type channel ::
          :push
          | :web_push
          | :email
          | :sms
          | :voice
          | :whatsapp
          | :slack
          | :teams
          | :telegram
          | :discord
          | :in_app
          | :webhook
  @type message_class ::
          :security
          | :action_required
          | :transactional
          | :operational
          | :social
          | :marketing
          | :system
  @type priority :: :high | :normal | :low
  @type preference :: :opt_in | :opt_out | :unset
  @type fate :: :drop | :defer | :digest | :inbox_only
  @type range :: %{days: [1..7], from: Time.t(), to: Time.t()}
  @type unreadable :: :unreadable

  @type target :: %{
          address: :present | :absent | :disabled,
          permission: :granted | :denied | :unknown,
          platform: :ios | :android | :web | nil
        }
  @type notification :: %{
          message_class: message_class(),
          security_subtype: :otp_oob | :email_verification | nil,
          priority: priority() | nil,
          expires_at: DateTime.t() | nil,
          on_expire: :drop | :inbox_only,
          timing_precision: :jittered | :strict,
          workflow_key: String.t() | nil,
          scope_key: String.t() | nil,
          sender_kind: :human | :system | :agent,
          scope: :match | :mismatch | unreadable()
        }
  @type frequency_policy :: %{
          limit: pos_integer() | nil,
          window_ms: pos_integer() | nil,
          fate: fate() | nil
        }
  @type category :: %{
          key: String.t(),
          locked: boolean(),
          enabled: boolean(),
          channel_defaults: %{optional(channel()) => :on | :off},
          frequency: frequency_policy() | nil,
          digest_allowed: boolean(),
          subtenant_override: boolean()
        }
  @type preferences :: %{
          category_channel: preference(),
          channel: preference(),
          workflow: preference(),
          scope_key: preference()
        }
  @type profile :: %{
          time_zone: String.t() | nil,
          quiet_hours: [range()],
          schedule: [range()] | nil,
          dnd_until: DateTime.t() | nil,
          email_in_quiet_hours: boolean(),
          digest: :instant | :digest | nil
        }
  @type consent :: %{
          state: :none | :pending | :active | :revoked | :expired,
          ref: term()
        }
  @type suppression :: %{reason: atom(), ref: term()}
  @type kill_switch :: :allow | {:pause, Relay.Id.t(), String.t()} | {:hold, String.t()}
  @type reading :: %{count: non_neg_integer(), free_at: DateTime.t() | nil}
  @type readings :: %{global: reading() | nil, policy: reading() | nil}

  @type t :: %__MODULE__{
          now: DateTime.t(),
          tenant_id: Relay.Id.t(),
          environment: Relay.Environment.t(),
          recipient_id: Relay.Id.t(),
          delivery_id: Relay.Id.t(),
          channel: channel(),
          target: target() | unreadable(),
          notification: notification(),
          category: category() | unreadable(),
          preferences: preferences() | unreadable(),
          profile: profile() | unreadable(),
          consent: consent() | unreadable(),
          suppression: suppression() | nil | unreadable(),
          kill_switch: kill_switch() | unreadable(),
          tenant_suspended: boolean() | unreadable(),
          tenant_time_zone: String.t() | unreadable(),
          device_time_zone: String.t() | nil,
          profile_country: String.t() | nil,
          country_time_zones: [String.t()] | nil | unreadable(),
          frequency: readings() | :unavailable,
          global_cap: pos_integer() | nil,
          jitter_spread_ms: non_neg_integer()
        }

  @doc "Builds a snapshot; raises when a field is missing or unknown."
  @spec new!(map() | keyword()) :: t()
  def new!(fields), do: struct!(__MODULE__, fields)
end
