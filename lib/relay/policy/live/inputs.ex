defmodule Relay.Policy.Live.Inputs do
  @moduledoc """
  Builds the input snapshot of one lattice evaluation from the database in one read path, inside the caller's scoped transaction (PC-58 (1)): the category with its sub-tenant setting applied (PC-57 (2)), the recipient's preference values at each level, the profile, the consent copy of the delivery's brand and channel (PC-59 (1)), the address state and its suppression (PC-59 (2)), the tenant's zone and the tenant and sub-tenant suspension. The frequency readings come later, outside the transaction (`Relay.Policy.FrequencyCounter`).

  A workflow whose category has no row yet is evaluated with the workflow's class and the class defaults. The suppression target digest is the address's blind index (`address` purpose) under the current and the next key. The release jitter spread is WF-58's PT15M.
  """

  alias Relay.Policy.Live.Store

  @channels Map.new(
              ~w(push web_push email sms voice whatsapp slack teams telegram discord in_app
                 webhook)a,
              &{Atom.to_string(&1), &1}
            )
  @classes Map.new(
             ~w(security action_required transactional operational social marketing system)a,
             &{Atom.to_string(&1), &1}
           )
  @priorities %{"low" => :low, "normal" => :normal, "high" => :high}
  @subtypes %{"otp_oob" => :otp_oob, "email_verification" => :email_verification}
  @senders %{"human" => :human, "system" => :system, "agent" => :agent}
  @fates %{"drop" => :drop, "defer" => :defer, "digest" => :digest, "inbox_only" => :inbox_only}
  @consents %{
    "none" => :none,
    "pending" => :pending,
    "active" => :active,
    "revoked" => :revoked,
    "expired" => :expired
  }
  @suppressions %{
    "hard_bounce" => :hard_bounce,
    "complaint" => :complaint,
    "invalid" => :invalid,
    "soft_bounce" => :soft_bounce,
    "manual" => :manual
  }
  @switches %{"on" => :on, "off" => :off}
  @address_kinds %{email: "email", sms: "phone", voice: "phone", whatsapp: "phone"}
  @days %{"mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7}
  @jitter_spread_ms 900_000

  @type category :: %{
          required(:key) => String.t(),
          required(:message_class) => atom(),
          required(:default_expires_ms) => pos_integer() | nil,
          optional(atom()) => term()
        }

  @doc "The channel atom of a channel name."
  @spec channel(String.t()) :: atom()
  def channel(name), do: Map.fetch!(@channels, name)

  @doc "The class atom of a class name."
  @spec class(String.t()) :: atom()
  def class(name), do: Map.fetch!(@classes, name)

  @doc "The priority atom of a priority name, `nil` for none."
  @spec priority(String.t() | nil) :: :low | :normal | :high | nil
  def priority(nil), do: nil
  def priority(name), do: Map.fetch!(@priorities, name)

  # PC-57 (1)
  # PC-57 (2)
  # PC-57 (3)
  @doc "The category of a row of `Relay.Policy.Live.Store.category/2` with the sub-tenant setting applied; without a row, the class defaults of `class`."
  @spec category(map() | nil, String.t(), atom()) :: category()
  def category(nil, key, class) do
    %{
      key: key,
      message_class: class,
      locked: class == :security,
      enabled: true,
      channel_defaults: %{},
      frequency: nil,
      digest_allowed: false,
      subtenant_override: false,
      default_expires_ms: nil
    }
  end

  def category(row, _key, _class) do
    tenant_defaults = defaults(row["channel_defaults"])

    %{
      key: row["key"],
      message_class: class(row["message_class"]),
      locked: row["locked"],
      enabled: enabled(row["setting_enabled"], row["enabled"]),
      channel_defaults: Map.merge(tenant_defaults, defaults(row["setting_channel_defaults"])),
      frequency: frequency(row),
      digest_allowed: row["digest_allowed"],
      subtenant_override: row["setting_id"] != nil,
      default_expires_ms: row["setting_default_expires_ms"] || row["default_expires_ms"]
    }
  end

  defp enabled(setting, _enabled) when is_boolean(setting), do: setting
  defp enabled(nil, enabled), do: enabled

  defp frequency(%{"setting_frequency_limit" => limit} = row) when is_integer(limit),
    do: frequency(row, "setting_")

  defp frequency(row), do: frequency(row, "")

  defp frequency(row, prefix) do
    case row[prefix <> "frequency_limit"] do
      nil ->
        nil

      limit ->
        %{
          limit: limit,
          window_ms: row[prefix <> "frequency_window_ms"],
          fate: Map.get(@fates, row[prefix <> "frequency_fate"])
        }
    end
  end

  defp defaults(nil), do: %{}

  defp defaults(map) when is_map(map) do
    for {name, value} <- map,
        Map.has_key?(@channels, name),
        Map.has_key?(@switches, value),
        into: %{},
        do: {channel(name), Map.fetch!(@switches, value)}
  end

  # PC-58 (1)
  # INV-43
  @doc """
  Builds a snapshot inside the caller's scoped transaction. `base` carries `:scope`, `:now`, `:delivery_id`, `:recipient_id`, `:subtenant_id`, `:channel` (an atom), `:category` (from `category/3`), `:workflow_key`, `:notification` (the class, subtype, priority, `expires_at` and sender as atoms), `:scope_match` (`:match` or `:mismatch`), `:kill_switch`, `:tenant_status` and `:frequency`.
  """
  @spec snapshot(map()) :: map()
  def snapshot(base) do
    %{category: category, channel: channel, recipient_id: recipient_id} = base
    channel_name = Atom.to_string(channel)
    {target, suppression} = target(recipient_id, channel, channel_name)

    Relay.Policy.snapshot!(
      now: base.now,
      tenant_id: base.scope.tenant_id,
      environment: base.scope.environment,
      recipient_id: recipient_id,
      delivery_id: base.delivery_id,
      channel: channel,
      target: target,
      notification:
        Map.merge(base.notification, %{
          workflow_key: base.workflow_key,
          scope_key: nil,
          scope: base.scope_match
        }),
      category: category,
      preferences: preferences(recipient_id, category.key, channel_name, base.workflow_key),
      profile: profile(recipient_id),
      consent: consent(recipient_id, base.subtenant_id, channel_name),
      suppression: suppression,
      kill_switch: base.kill_switch,
      tenant_suspended: suspended?(base.tenant_status, base.subtenant_id),
      tenant_time_zone: Store.tenant_time_zone(base.scope.tenant_id) || :unreadable,
      device_time_zone: nil,
      profile_country: nil,
      country_time_zones: nil,
      frequency: base.frequency,
      global_cap: nil,
      jitter_spread_ms: @jitter_spread_ms
    )
  end

  @doc "The notification fields of a snapshot from the stored names."
  @spec notification(map()) :: map()
  def notification(fields) do
    %{
      message_class: class(fields.message_class),
      security_subtype: Map.get(@subtypes, fields.security_subtype),
      priority: priority(fields.priority),
      expires_at: fields.expires_at,
      sender_kind: Map.get(@senders, fields.sender_type, :system)
    }
  end

  # PC-12
  # PC-13
  defp preferences(recipient_id, category_key, channel, workflow_key) do
    rows = Store.preferences(recipient_id, category_key, channel, workflow_key, nil)

    Map.new([:category_channel, :channel, :workflow, :scope_key], fn level ->
      name = Atom.to_string(level)
      {level, value(for %{"level" => ^name, "value" => value} <- rows, do: value)}
    end)
  end

  defp value(values) do
    cond do
      "opt_out" in values -> :opt_out
      "opt_in" in values -> :opt_in
      true -> :unset
    end
  end

  # PC-45
  # PC-57 (5)
  defp profile(recipient_id) do
    zone = Store.recipient_time_zone(recipient_id)

    case Store.profile(recipient_id) do
      nil ->
        %{
          time_zone: zone,
          quiet_hours: [],
          schedule: nil,
          dnd_until: nil,
          email_in_quiet_hours: false,
          digest: nil
        }

      row ->
        %{
          time_zone: zone,
          quiet_hours: ranges(row["quiet_hours"]),
          schedule: if(row["schedule"] in [nil, []], do: nil, else: ranges(row["schedule"])),
          dnd_until: row["dnd_until"],
          email_in_quiet_hours: row["quiet_hours_email"] == true,
          digest: nil
        }
    end
  end

  defp ranges(ranges) when is_list(ranges) do
    for %{"day" => day, "start" => from, "end" => to} <- ranges,
        Map.has_key?(@days, day),
        do: %{days: [Map.fetch!(@days, day)], from: time(from), to: time(to)}
  end

  defp ranges(_other), do: []

  defp time(text), do: Time.from_iso8601!(text <> ":00")

  # PC-59 (1)
  # PC-21
  defp consent(recipient_id, subtenant_id, channel) do
    found =
      Enum.find(
        Store.consents(recipient_id),
        &(&1["channel"] == channel and &1["brand_subtenant_id"] == subtenant_id)
      )

    case found do
      nil -> %{state: :none, ref: nil}
      row -> %{state: Map.fetch!(@consents, row["status"]), ref: ref(row["consent_id"])}
    end
  end

  # PC-8
  # PC-59 (2)
  # CH-40
  defp target(recipient_id, channel, channel_name) do
    case Map.fetch(@address_kinds, channel) do
      {:ok, kind} ->
        row = Store.address(recipient_id, kind)
        target = %{address: address(row), permission: :unknown, platform: nil}
        {target, suppression(row, channel_name)}

      :error ->
        {%{address: :present, permission: :unknown, platform: nil}, nil}
    end
  end

  defp address(%{"state" => "active"}), do: :present
  defp address(%{"state" => "disabled"}), do: :disabled
  defp address(nil), do: :absent

  defp suppression(nil, _channel), do: nil

  defp suppression(row, channel) do
    digests = Enum.reject([row["address_bidx"], row["address_bidx_next"]], &is_nil/1)

    case Store.suppressions(channel, digests) do
      [] -> nil
      [hit | _] -> %{reason: suppression_reason(hit["reason"]), ref: ref(hit["suppression_id"])}
    end
  end

  defp suppression_reason(reason), do: Map.fetch!(@suppressions, reason)

  # TN-10
  defp suspended?(status, subtenant_id) do
    status not in [:active, nil] or
      (subtenant_id != nil and Store.subtenant_state(subtenant_id) == "suspended")
  end

  defp ref(nil), do: nil
  defp ref(id), do: Relay.Id.to_string(id)
end
