defmodule Relay.Policy.Live.Inputs do
  @moduledoc """
  Builds the input snapshot of one lattice evaluation from the database in one read path, inside the caller's scoped transaction (PC-58 (1)): the category with its sub-tenant setting applied (PC-57 (2)), the recipient's preference values at each level, the profile, the consent copy of the delivery's brand and channel (PC-59 (1)), the address state and its suppression (PC-59 (2)), on a push channel the recipient's devices (CH-28), the tenant's zone and the tenant and sub-tenant suspension, what the compliance table asks of the delivery (PC-40) and, for a marketing delivery on e-mail, SMS or voice, the İYS input (PC-27). The frequency readings come later, outside the transaction (`Relay.Policy.FrequencyCounter`).

  A workflow whose category has no row yet is evaluated with the workflow's class and the class defaults. The suppression target digest is the address's blind index (`address` purpose) under the current and the next key. The release jitter spread is WF-58's PT15M, shrunk or zeroed by the tenant's jitter control and zeroed by a send's `timing_precision: strict` (`Relay.Timing`).

  The compliance input is resolved by `Relay.Compliance` from the data set contents the caller read outside the transaction (`Relay.Policy.Live.compliance/1`): the recipient's countries are its profile country and the countries of its phone number's country calling code, or the country of the tenant's region when it has neither; the legal recipient type is the consent record's, then the profile's `legal_type`, then `individual`. A revocation on a channel the deciding row's revocation scope names is read as a revocation on this channel too (PC-61). The time zone chain gets the zone the most recently seen device reported and the zone of a profile country that has a single one (WF-45).

  On `push` and `web_push` the target is read from the recipient's devices that are not disabled (`Relay.Devices`), the same rule the channel step uses: no device on the channel is an absent target (`channel.no_address`), devices of which none is permitted for the class are a denied permission (`channel.no_permission`), and otherwise the permission is granted and the platform is the one of the most recently seen permitted device (`apns` is `ios`, `web_push` is `web`, the others `android`).
  """

  alias Relay.Policy.IysGate
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
  @kinds %{
    "none" => :none,
    "legitimate_interest" => :legitimate_interest,
    "soft_opt_in" => :soft_opt_in,
    "explicit_opt_in" => :explicit_opt_in
  }
  @recipient_types %{"individual" => :individual, "merchant" => :merchant}
  @platforms %{ios: "ios", android: "android", web: "web"}
  @iys_channels [:email, :sms, :voice]
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
    "manual" => :manual,
    "refusal" => :refusal
  }
  @switches %{"on" => :on, "off" => :off}
  @address_kinds %{email: "email", sms: "phone", voice: "phone", whatsapp: "phone"}
  @device_channels [:push, :web_push]
  @days %{"mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7}

  @type category :: %{
          required(:key) => String.t(),
          required(:message_class) => atom(),
          required(:default_expires_ms) => pos_integer() | nil,
          optional(atom()) => term()
        }

  @type compliance :: %{
          table: map(),
          version: pos_integer(),
          refusals: %{optional(String.t()) => [String.t()]},
          country_zones: [map()] | nil
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
      density: nil,
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
      density: row["density"],
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
  Builds a snapshot inside the caller's scoped transaction. `base` carries `:scope`, `:now`, `:delivery_id`, `:recipient_id`, `:subtenant_id`, `:channel` (an atom), `:category` (from `category/3`), `:workflow_key`, `:notification` (the class, subtype, priority, `expires_at` and sender as atoms), `:scope_match` (`:match` or `:mismatch`), `:kill_switch`, `:tenant_status`, `:frequency` and `:compliance` (from `Relay.Policy.Live.compliance/1`).
  """
  @spec snapshot(map()) :: map()
  def snapshot(base) do
    %{category: category, channel: channel, recipient_id: recipient_id} = base
    channel_name = Atom.to_string(channel)
    class = base.notification.message_class
    {target, suppression, digest} = target(recipient_id, channel, channel_name, class)
    recipient = Store.recipient(recipient_id) || %{}
    tenant = Store.tenant(base.scope.tenant_id) || %{}
    consents = brand_consents(recipient_id, base.subtenant_id)

    {compliance, revocations} =
      compliance(base.compliance, %{
        channel: channel_name,
        class: Atom.to_string(class),
        recipient_type: recipient_type(consents, channel_name, recipient),
        platform: platform_name(target),
        countries: countries(base.compliance, recipient),
        fallback: fallback(tenant)
      })

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
      profile: profile(recipient_id, recipient["timezone"]),
      consent: consent(consents, channel_name, revocations),
      compliance: compliance,
      iys: iys(base, class, channel, digest),
      iys_stale_after_ms: IysGate.stale_stop_ms(),
      suppression: suppression,
      kill_switch: base.kill_switch,
      tenant_suspended: suspended?(base.tenant_status, base.subtenant_id),
      tenant_time_zone: tenant["default_timezone"] || :unreadable,
      device_time_zone: recipient["device_time_zone"],
      profile_country: recipient["country"],
      country_time_zones: country_zones(base.compliance, recipient["country"]),
      frequency: base.frequency,
      global_cap: nil,
      jitter_spread_ms: release_spread(base.notification)
    )
  end

  # PC-40
  # PC-41
  # PC-54
  # INV-17
  # INV-43
  defp compliance(%{table: table, version: version, refusals: refusals}, query) do
    resolved = Relay.Compliance.resolve(table, refusals, query)

    detail = %{
      compliance_row: resolved.row,
      compliance_country: resolved.country,
      compliance_version: version,
      platform_row: resolved.platform_row,
      required_consent: resolved.required,
      recipient_type: query.recipient_type
    }

    {%{
       required: Map.fetch!(@kinds, resolved.required),
       accepted: Enum.map(resolved.accepted, &Map.fetch!(@kinds, &1)),
       recipient_type: Map.fetch!(@recipient_types, query.recipient_type),
       default: resolved.default,
       legal_windows: resolved.legal_windows,
       detail: Map.reject(detail, fn {_key, value} -> is_nil(value) end)
     }, resolved.revocation_channels}
  end

  defp compliance(_unreadable, _query), do: {:unreadable, []}

  # PC-40
  # PC-47
  defp countries(%{table: table}, recipient),
    do: Relay.Compliance.candidates(table, recipient["calling_code"], recipient["country"])

  defp countries(_unreadable, _recipient), do: []

  defp fallback(%{"region" => region}) when is_binary(region),
    do: Relay.Compliance.region_country(region)

  defp fallback(_tenant), do: "*"

  # PC-24
  defp recipient_type(consents, channel, recipient) do
    own = Enum.find(consents, &(&1["channel"] == channel)) || %{}
    type = own["recipient_type"] || recipient["legal_type"]
    if Map.has_key?(@recipient_types, type), do: type, else: "individual"
  end

  defp platform_name(%{platform: platform}), do: Map.get(@platforms, platform)

  # WF-45
  # PC-58 (4)
  defp country_zones(%{country_zones: zones}, country) when is_list(zones) and is_binary(country),
    do: for(%{"country" => ^country, "zone" => zone} <- zones, do: zone)

  defp country_zones(_bundle, _country), do: nil

  # PC-27
  # PC-33
  # INV-19
  defp iys(base, :marketing, channel, digest)
       when channel in @iys_channels and is_binary(digest) do
    status = IysGate.status(base.scope, base.subtenant_id, channel, digest)
    warn(status, base.now)
    status
  end

  defp iys(_base, _class, _channel, _digest), do: :not_applicable

  # PC-33
  defp warn({:cached, _state, synced}, now) when is_integer(synced) do
    age = DateTime.to_unix(now, :millisecond) - synced

    if age >= IysGate.stale_warning_ms(),
      do: :telemetry.execute([:relay, :policy, :iys_copy_stale], %{age_ms: age}, %{})

    :ok
  end

  defp warn(_status, _now), do: :ok

  # WF-42
  # WF-58
  defp release_spread(notification) do
    precision = Map.get(notification, :timing_precision)
    Relay.Timing.spread(Relay.Timing.read(), :release, precision)
  end

  @doc "The notification fields of a snapshot from the stored names; `timing`, `max_defer_until` and `timing_released` give the `next_break` of a `timing: next_break` send (WF-56)."
  @spec notification(map()) :: map()
  def notification(fields) do
    %{
      message_class: class(fields.message_class),
      security_subtype: Map.get(@subtypes, fields.security_subtype),
      priority: priority(fields.priority),
      expires_at: fields.expires_at,
      on_expire: if(Map.get(fields, :on_expire) == "inbox_only", do: :inbox_only, else: :drop),
      timing_precision: Relay.Timing.precision(Map.get(fields, :timing_precision)),
      sender_kind: Map.get(@senders, fields.sender_type, :system),
      next_break: next_break(fields)
    }
  end

  # WF-56
  defp next_break(%{timing: "next_break", max_defer_until: %DateTime{} = until} = fields),
    do: %{until: until, released: Map.get(fields, :timing_released) == true}

  defp next_break(_fields), do: nil

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
  defp profile(recipient_id, zone) do
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
  defp brand_consents(recipient_id, subtenant_id) do
    for %{"brand_subtenant_id" => ^subtenant_id} = row <- Store.consents(recipient_id), do: row
  end

  # PC-59 (1)
  # PC-21
  # PC-39
  defp consent(rows, channel, revocations) do
    own = Enum.find(rows, &(&1["channel"] == channel))
    covering = Enum.find(rows, &(&1["status"] == "revoked" and &1["channel"] in revocations))

    case {own, covering} do
      {nil, nil} -> %{state: :none, ref: nil, kind: nil}
      {%{"status" => "revoked"} = row, _covering} -> consent(row)
      {_own, %{} = row} -> consent(row)
      {row, nil} -> consent(row)
    end
  end

  defp consent(row) do
    %{
      state: Map.fetch!(@consents, row["status"]),
      ref: ref(row["consent_id"]),
      kind: Map.get(@kinds, row["consent_kind"])
    }
  end

  # PC-8
  # PC-59 (2)
  # CH-40
  defp target(recipient_id, channel, channel_name, class) do
    case Map.fetch(@address_kinds, channel) do
      {:ok, kind} ->
        row = Store.address(recipient_id, kind)
        target = %{address: address(row), permission: :unknown, platform: nil}
        {target, suppression(row, channel_name), row && row["address_bidx"]}

      :error when channel in @device_channels ->
        {device(recipient_id, channel, class), nil, nil}

      :error ->
        {%{address: :present, permission: :unknown, platform: nil}, nil, nil}
    end
  end

  # CH-28
  # CH-29
  # PC-16
  defp device(recipient_id, channel, class) do
    devices =
      recipient_id
      |> Relay.Devices.current()
      |> Enum.filter(&(Relay.Devices.channel(&1["platform"]) == channel))

    permitted = Enum.filter(devices, &Relay.Devices.permitted?(&1["permission"], class))

    case {devices, permitted} do
      {[], _none} ->
        %{address: :absent, permission: :unknown, platform: nil}

      {[first | _], []} ->
        %{address: :present, permission: :denied, platform: platform(first)}

      {_devices, [first | _]} ->
        %{address: :present, permission: :granted, platform: platform(first)}
    end
  end

  defp platform(%{"platform" => "apns"}), do: :ios
  defp platform(%{"platform" => "web_push"}), do: :web
  defp platform(%{"platform" => _android}), do: :android

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
