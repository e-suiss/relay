defmodule Relay.Policy.Engine do
  @moduledoc """
  The policy lattice: a pure function of a `Relay.Policy.Snapshot` (PC-8, PC-58, WF-41). The order is fixed:

  1. Gates, which nothing passes (INV-15): kill switch and tenant suspension (1a), suppression (1b), refusal (1c), compliance (1d), the channel's technical state and the OTP subtype channel rule (1e), sub-tenant scope (1f).
  2. Exemption: a locked category skips the filters, never a gate. `security` is always locked; `system` has no preference surface.
  3. Filters, all of which must allow: the tenant's category switch (3a), the category × channel value or its default (3b, which a `scope_key` value overrides), the general channel switch, the workflow value (3c), a `scope_key` mute (3d) and, for `action_required`, which is never deferred, the weekly availability schedule (3e).
  4. Expiry: a delivery at or past `expires_at` expires.
  5. Shapers, for `transactional`, `operational`, `social` and `marketing` only: the availability schedule, the tenant zone window of PC-48, quiet hours, `dnd_until`, then the frequency cap. A blocked delivery is deferred to the next allowed instant within eight days and before `expires_at`, plus the WF-42 release jitter, or expires when there is none (PC-46).

  Results:

  * `{:send, info}`: `info` carries the clamped `priority`, `priority_clamped`, the frequency `counters` to record once the delivery is sent, the `frequency` state (`:counted`, `:unavailable` or `:exempt`) and, when it was resolved, the `timezone` and its `timezone_source`.
  * `{:skip, reason, rule_id, detail}`: a gate or filter decision, or a frequency fate that drops the delivery.
  * `{:defer, reason, rule_id, deferred_until, detail}`: a shaper decision.
  * `{:expire, rule_id, detail}`: `expires_at` has passed, or no allowed instant precedes it.
  * `{:pause, rule_id, detail}`: a kill switch pauses the delivery (TN-40).
  * `{:error, {:input_unavailable, input}}`: an input the decision needs could not be read; nothing is recorded and the job retries (INV-43).
  """

  alias Relay.Policy.Defaults
  alias Relay.Policy.Frequency
  alias Relay.Policy.Priority
  alias Relay.Policy.Rules
  alias Relay.Policy.Snapshot
  alias Relay.Policy.Window
  alias Relay.Policy.Zone

  @type detail :: %{optional(atom()) => term()}
  @type send_info :: %{
          priority: Snapshot.priority(),
          priority_clamped: boolean(),
          counters: [Frequency.key()],
          frequency: :counted | :unavailable | :exempt,
          timezone: Relay.TimeZone.t() | nil,
          timezone_source: Zone.source() | nil
        }
  @type input ::
          :kill_switch
          | :tenant_suspended
          | :suppression
          | :consent
          | :target
          | :scope
          | :category
          | :preferences
          | :profile
          | :time_zone
  @type result ::
          {:send, send_info()}
          | {:skip, atom(), String.t(), detail()}
          | {:defer, atom(), String.t(), DateTime.t(), detail()}
          | {:expire, String.t(), detail()}
          | {:pause, String.t(), detail()}
          | {:error, {:input_unavailable, input()}}

  @consent_channels [:email, :sms, :voice, :whatsapp]
  @otp_channels [:sms, :whatsapp, :voice]
  @permission_channels [:push, :web_push]
  @quiet_channels [:push, :web_push, :sms, :voice, :whatsapp, :slack, :teams, :telegram, :discord]
  @deferrable [:transactional, :operational, :social, :marketing]
  @pc48_classes [:marketing, :social]
  @pc48_window [%{days: [1, 2, 3, 4, 5, 6, 7], from: ~T[10:00:00], to: ~T[18:00:00]}]
  @horizon_days 8

  # PC-8
  # PC-58 (1)
  # WF-41
  # INV-15
  # INV-43
  @doc "Evaluates the lattice for one delivery."
  @spec evaluate(Snapshot.t()) :: result()
  def evaluate(%Snapshot{} = s) do
    with :pass <- gates(s),
         :pass <- filters(s),
         :pass <- expiry(s) do
      shape(s)
    end
  end

  # PC-58 (6)
  @doc "The frequency counters that apply to the delivery of a snapshot, for reading them before the evaluation."
  @spec counters(Snapshot.t()) :: [Frequency.key()]
  def counters(%Snapshot{category: %{key: key, frequency: policy}} = s),
    do: Frequency.keys(s.notification.message_class, s.channel, key, policy, s.global_cap)

  def counters(%Snapshot{}), do: []

  # PC-8
  defp gates(s) do
    with :pass <- kill_switch(s),
         :pass <- tenant(s),
         :pass <- suppression(s),
         :pass <- refusal(s),
         :pass <- compliance(s),
         :pass <- target(s),
         :pass <- otp_channel(s) do
      scope(s)
    end
  end

  # PC-8
  # TN-40
  # TN-38
  defp kill_switch(%{kill_switch: :allow}), do: :pass

  defp kill_switch(%{kill_switch: {:pause, id, rule_id}}) do
    if Rules.kill_switch?(rule_id),
      do: {:pause, rule_id, %{kill_switch_id: id}},
      else: unavailable(:kill_switch)
  end

  defp kill_switch(_s), do: unavailable(:kill_switch)

  defp tenant(%{tenant_suspended: false}), do: :pass
  defp tenant(%{tenant_suspended: true}), do: skip(:tenant_suspended, %{})
  defp tenant(_s), do: unavailable(:tenant_suspended)

  # PC-8
  # CH-40
  defp suppression(%{suppression: nil}), do: :pass

  defp suppression(%{suppression: %{reason: reason, ref: ref}}),
    do: skip(:suppression_address, %{suppression_reason: reason, suppression_ref: ref})

  defp suppression(_s), do: unavailable(:suppression)

  # PC-8
  # INV-18
  defp refusal(%{notification: %{message_class: :marketing}, consent: consent}) do
    case consent do
      %{state: :revoked, ref: ref} -> skip(:consent_revoked, %{consent_ref: ref})
      %{state: _state} -> :pass
      _unreadable -> unavailable(:consent)
    end
  end

  defp refusal(_s), do: :pass

  # PC-8
  # PC-58 (3)
  defp compliance(%{notification: %{message_class: :marketing}, channel: channel} = s)
       when channel in @consent_channels do
    case s.consent do
      %{state: :active} -> :pass
      %{state: :expired, ref: ref} -> skip(:consent_expired, %{consent_ref: ref})
      %{state: _none_or_pending, ref: ref} -> skip(:consent_missing, %{consent_ref: ref})
      _unreadable -> unavailable(:consent)
    end
  end

  defp compliance(_s), do: :pass

  # PC-8
  # PC-16
  defp target(%{target: %{address: :absent}}), do: skip(:channel_no_address, %{})
  defp target(%{target: %{address: :disabled}}), do: skip(:channel_address_disabled, %{})

  defp target(%{target: %{address: :present, permission: :denied}, channel: channel})
       when channel in @permission_channels,
       do: skip(:channel_no_permission, %{permission: :denied})

  defp target(%{target: %{address: :present}}), do: :pass
  defp target(_s), do: unavailable(:target)

  # PC-8
  # PC-51
  # INV-23
  defp otp_channel(%{notification: %{security_subtype: :otp_oob}, channel: channel})
       when channel not in @otp_channels,
       do: skip(:otp_channel_forbidden, %{security_subtype: :otp_oob})

  defp otp_channel(%{notification: %{security_subtype: :email_verification}, channel: channel})
       when channel != :email,
       do: skip(:email_verification_only, %{security_subtype: :email_verification})

  defp otp_channel(_s), do: :pass

  # PC-8
  # TN-5
  defp scope(%{notification: %{scope: :match}}), do: :pass
  defp scope(%{notification: %{scope: :mismatch}}), do: skip(:scope_mismatch, %{})
  defp scope(_s), do: unavailable(:scope)

  # PC-8
  # PC-6
  # PC-11
  defp filters(%{category: %{locked: true}}), do: :pass
  defp filters(%{notification: %{message_class: :security}}), do: :pass
  defp filters(%{category: :unreadable}), do: unavailable(:category)
  defp filters(%{category: %{enabled: false}} = s), do: tenant_off(s)
  defp filters(%{notification: %{message_class: :system}}), do: :pass
  defp filters(%{preferences: :unreadable}), do: unavailable(:preferences)

  defp filters(s) do
    with :pass <- category_channel(s),
         :pass <- off(s.preferences.channel, :preference_channel, "channel"),
         :pass <- off(s.preferences.workflow, :preference_workflow, "workflow"),
         :pass <- off(s.preferences.scope_key, :preference_scope_key, "scope_key") do
      availability(s)
    end
  end

  # PC-8
  # PC-15
  defp tenant_off(s) do
    subtenant = s.category.subtenant_override
    skip(:preference_tenant_category, %{level: "tenant", subtenant_override: subtenant})
  end

  # PC-8
  # PC-12
  # PC-13
  defp category_channel(%{preferences: %{scope_key: value}}) when value in [:opt_in, :opt_out],
    do: :pass

  defp category_channel(%{preferences: %{category_channel: :opt_in}}), do: :pass

  defp category_channel(%{preferences: %{category_channel: :opt_out}}),
    do: skip(:preference_category_channel, %{level: "category_channel"})

  defp category_channel(s) do
    class = s.notification.message_class
    platform = if is_map(s.target), do: s.target.platform, else: nil

    case Defaults.default(class, s.channel, s.category.channel_defaults, platform) do
      {:on, _source} ->
        :pass

      {:off, source} ->
        skip(:preference_category_default, %{level: "category_channel", source: source})
    end
  end

  defp off(:opt_out, rule, level), do: skip(rule, %{level: level})
  defp off(_value, _rule, _level), do: :pass

  # PC-8
  defp availability(%{notification: %{message_class: :action_required}} = s) do
    with {:ok, profile} <- readable(s.profile, :profile) do
      if ranges?(profile.schedule) and quiet_channel?(s.channel, profile),
        do: schedule_filter(s, profile.schedule),
        else: :pass
    end
  end

  defp availability(_s), do: :pass

  defp schedule_filter(s, schedule) do
    with {:ok, {zone, source}} <- zone(s) do
      if Window.blocking(s.now, zone, [{:preference_schedule, {:only, schedule}}]),
        do: skip(:preference_schedule, Map.put(zone_detail(s, zone, source), :level, "schedule")),
        else: :pass
    end
  end

  # PC-49
  # WF-38
  defp expiry(%{notification: %{expires_at: nil}}), do: :pass

  defp expiry(%{notification: %{expires_at: expires_at}, now: now}) do
    if DateTime.compare(now, expires_at) == :lt,
      do: :pass,
      else: {:expire, Rules.id(:expiry_expires_at), %{expires_at: expires_at}}
  end

  # WF-41
  # INV-24
  # PC-53
  defp shape(%{notification: %{message_class: class}} = s) when class not in @deferrable,
    do: deliver(s, nil, :exempt)

  defp shape(s) do
    with {:ok, profile} <- readable(s.profile, :profile),
         {:ok, {zone, _source} = tz} <- zone(s) do
      constraints = constraints(s, profile, tz)

      case Window.blocking(s.now, zone, constraints) do
        nil -> frequency(s, tz, constraints)
        name -> defer(s, name, s.now, tz, constraints, %{})
      end
    end
  end

  # PC-45
  # PC-48
  # PC-58 (4)
  # PC-58 (5)
  defp constraints(s, profile, {_zone, source}) do
    quiet? = quiet_channel?(s.channel, profile)
    pc48? = source == :tenant_default and s.notification.message_class in @pc48_classes
    schedule = profile.schedule
    quiet = profile.quiet_hours
    dnd = profile.dnd_until

    Enum.concat([
      on(quiet? and ranges?(schedule), {:schedule_deferred, {:only, schedule}}),
      on(pc48?, {:tenant_timezone_window_deferred, {:only, @pc48_window}}),
      on(quiet? and ranges?(quiet), {:quiet_hours_deferred, {:quiet, quiet}}),
      on(quiet? and match?(%DateTime{}, dnd), {:dnd_deferred, {:until, dnd}})
    ])
  end

  defp on(true, constraint), do: [constraint]
  defp on(false, _constraint), do: []

  defp ranges?(ranges), do: is_list(ranges) and ranges != []

  # PC-45
  defp quiet_channel?(:email, profile), do: profile.email_in_quiet_hours == true
  defp quiet_channel?(channel, _profile), do: channel in @quiet_channels

  # PC-50
  # INV-45
  # WF-41
  defp frequency(s, tz, constraints) do
    class = s.notification.message_class
    policy = s.category.frequency
    keys = Frequency.keys(class, s.channel, s.category.key, policy, s.global_cap)

    case Frequency.check(keys, s.frequency) do
      :pass ->
        deliver(s, tz, if(keys == [], do: :exempt, else: :counted))

      :unavailable ->
        deliver(s, tz, :unavailable)

      {:capped, kind, free_at} ->
        capped(s, tz, constraints, Frequency.fate(class, policy), kind, free_at || s.now)
    end
  end

  # PC-50
  # PC-58 (6)
  defp capped(s, tz, _constraints, :drop, kind, _free_at),
    do: skip(:frequency_dropped, Map.put(zone_detail(s, tz), :counter, kind))

  defp capped(%{channel: :in_app} = s, tz, _constraints, :inbox_only, _kind, _free_at),
    do: deliver(s, tz, :counted)

  defp capped(s, tz, _constraints, :inbox_only, kind, _free_at),
    do: skip(:frequency_inbox_only, Map.put(zone_detail(s, tz), :counter, kind))

  defp capped(s, tz, constraints, fate, kind, free_at) do
    rule = if fate == :digest, do: :frequency_digest, else: :frequency_deferred
    from = if DateTime.compare(free_at, s.now) == :gt, do: free_at, else: s.now
    defer(s, rule, from, tz, constraints, %{counter: kind})
  end

  # PC-46
  # PC-58 (5)
  # WF-42
  defp defer(s, rule, from, {zone, _source} = tz, constraints, extra) do
    limit = limit(s)
    detail = Map.merge(zone_detail(s, tz), extra)

    case Window.next_allowed(from, limit, zone, constraints) do
      {:ok, at} ->
        until = DateTime.add(at, release(s, at, zone, constraints, limit), :millisecond)
        detail = Map.put(detail, :local_until, iso_local(until, zone))
        {:defer, Rules.reason(rule), Rules.id(rule), until, detail}

      :none ->
        {:expire, Rules.id(:expiry_no_window), Map.put(detail, :deferred_by, Rules.id(rule))}
    end
  end

  defp limit(%{now: now, notification: %{expires_at: expires_at}}) do
    horizon = DateTime.add(now, @horizon_days, :day)

    if is_nil(expires_at) or DateTime.compare(horizon, expires_at) == :lt,
      do: horizon,
      else: expires_at
  end

  # WF-42
  defp release(s, at, zone, constraints, limit) do
    spread = Window.allowed_ms(at, limit, zone, constraints, s.jitter_spread_ms)
    Relay.Jitter.release(s.tenant_id, s.environment, s.recipient_id, iso_local(at, zone), spread)
  end

  # PC-58 (7)
  # API-22
  defp deliver(s, tz, frequency) do
    {priority, clamped?} = Priority.clamp(s.notification.message_class, s.notification.priority)
    {zone, source} = tz || {nil, nil}

    {:send,
     %{
       priority: priority,
       priority_clamped: clamped?,
       counters: if(frequency == :exempt, do: [], else: counters(s)),
       frequency: frequency,
       timezone: zone,
       timezone_source: source
     }}
  end

  # WF-45
  # PC-58 (4)
  defp zone(s) do
    profile_zone = if is_map(s.profile), do: s.profile.time_zone, else: nil

    with {:ok, zones} <- readable(s.country_time_zones, :time_zone),
         {:ok, tenant_zone} <- readable(s.tenant_time_zone, :time_zone) do
      case Zone.resolve(profile_zone, s.device_time_zone, zones, tenant_zone) do
        {:ok, _zone_and_source} = ok -> ok
        :error -> unavailable(:time_zone)
      end
    end
  end

  defp zone_detail(s, {zone, source}), do: zone_detail(s, zone, source)

  defp zone_detail(s, zone, source),
    do: %{timezone: zone, timezone_source: source, local_time: iso_local(s.now, zone)}

  defp iso_local(at, zone), do: at |> Zone.local(zone) |> NaiveDateTime.to_iso8601()

  defp readable(:unreadable, input), do: unavailable(input)
  defp readable(value, _input), do: {:ok, value}

  defp skip(rule, detail), do: {:skip, Rules.reason(rule), Rules.id(rule), detail}

  defp unavailable(input), do: {:error, {:input_unavailable, input}}
end
