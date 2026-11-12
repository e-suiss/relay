defmodule Relay.Policy.Rules do
  @moduledoc """
  The rules of the policy lattice: for each rule its `rule_id` in the `<area>.<rule>` form of the rule dictionary and its `reason` family (DS-25, DS-47). Every rule id the lattice writes comes from this table, so a test can match the table against the `rule_dictionary` dataset. Kill switch rules are the exception: they come from the kill switch decision (`killswitch.*`) and are passed through unchanged.
  """

  @type name ::
          :tenant_suspended
          | :suppression_address
          | :consent_missing
          | :consent_revoked
          | :consent_expired
          | :channel_no_address
          | :channel_address_disabled
          | :channel_no_permission
          | :otp_channel_forbidden
          | :email_verification_only
          | :scope_mismatch
          | :preference_tenant_category
          | :preference_category_channel
          | :preference_channel
          | :preference_workflow
          | :preference_scope_key
          | :preference_schedule
          | :preference_category_default
          | :quiet_hours_deferred
          | :schedule_deferred
          | :dnd_deferred
          | :tenant_timezone_window_deferred
          | :next_break_deferred
          | :frequency_dropped
          | :frequency_deferred
          | :frequency_digest
          | :frequency_inbox_only
          | :expiry_expires_at
          | :expiry_no_window
  @type kind :: :gate | :filter | :shaper | :terminal
  @type outcome :: :skip | :defer | :expire

  # DS-47 (5)
  # DS-25
  @rules %{
    tenant_suspended: {"tenant.suspended", :tenant_suspended, :gate, :skip},
    suppression_address: {"suppression.address", :suppressed_address, :gate, :skip},
    consent_missing: {"consent.missing", :consent_missing, :gate, :skip},
    consent_revoked: {"consent.revoked", :consent_revoked, :gate, :skip},
    consent_expired: {"consent.expired", :consent_missing, :gate, :skip},
    channel_no_address: {"channel.no_address", :no_address, :gate, :skip},
    channel_address_disabled: {"channel.address_disabled", :no_address, :gate, :skip},
    channel_no_permission: {"channel.no_permission", :no_permission, :gate, :skip},
    otp_channel_forbidden:
      {"channel_policy.otp_channel_forbidden", :channel_policy, :gate, :skip},
    email_verification_only:
      {"channel_policy.email_verification_only", :channel_policy, :gate, :skip},
    scope_mismatch: {"scope.mismatch", :scope_mismatch, :gate, :skip},
    preference_tenant_category: {"preference.tenant_category", :preference_off, :filter, :skip},
    preference_category_channel: {"preference.category_channel", :preference_off, :filter, :skip},
    preference_channel: {"preference.channel", :preference_off, :filter, :skip},
    preference_workflow: {"preference.workflow", :preference_off, :filter, :skip},
    preference_scope_key: {"preference.scope_key", :preference_off, :filter, :skip},
    preference_schedule: {"preference.schedule", :preference_off, :filter, :skip},
    preference_category_default: {"preference.category_default", :preference_off, :filter, :skip},
    quiet_hours_deferred: {"quiet_hours.deferred", :quiet_hours, :shaper, :defer},
    schedule_deferred: {"schedule.deferred", :schedule, :shaper, :defer},
    dnd_deferred: {"dnd.deferred", :dnd, :shaper, :defer},
    tenant_timezone_window_deferred:
      {"tenant_timezone_window.deferred", :tenant_timezone_window, :shaper, :defer},
    next_break_deferred: {"next_break.deferred", :next_break, :shaper, :defer},
    frequency_dropped: {"frequency.dropped", :frequency_capped, :shaper, :skip},
    frequency_deferred: {"frequency.deferred", :frequency_capped, :shaper, :defer},
    frequency_digest: {"frequency.digest", :frequency_capped, :shaper, :defer},
    frequency_inbox_only: {"frequency.inbox_only", :frequency_capped, :shaper, :skip},
    expiry_expires_at: {"expiry.expires_at", :expired, :terminal, :expire},
    expiry_no_window: {"expiry.no_window", :expired, :terminal, :expire}
  }

  @doc "The rule id of a lattice rule."
  @spec id(name()) :: String.t()
  def id(name), do: @rules |> Map.fetch!(name) |> elem(0)

  @doc "The reason family of a lattice rule."
  @spec reason(name()) :: atom()
  def reason(name), do: @rules |> Map.fetch!(name) |> elem(1)

  @doc "The kind of a lattice rule: gate, filter, shaper or terminal."
  @spec kind(name()) :: kind()
  def kind(name), do: @rules |> Map.fetch!(name) |> elem(2)

  @doc "The outcome a lattice rule records."
  @spec outcome(name()) :: outcome()
  def outcome(name), do: @rules |> Map.fetch!(name) |> elem(3)

  # DS-47 (4)
  @doc "Every rule id the lattice writes itself, sorted."
  @spec ids() :: [String.t()]
  def ids, do: @rules |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  @doc "Every rule name, sorted."
  @spec names() :: [name()]
  def names, do: @rules |> Map.keys() |> Enum.sort()

  # DS-47 (1)
  @doc "Returns true if `rule_id` is a kill switch rule (`killswitch.<rule>`, optionally with a `:<reference>`)."
  @spec kill_switch?(term()) :: boolean()
  def kill_switch?(rule_id),
    do: is_binary(rule_id) and Regex.match?(~r/\Akillswitch\.[a-z_]+(:[^:\s]+)?\z/, rule_id)
end
