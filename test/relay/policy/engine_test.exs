defmodule Relay.Policy.EngineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Relay.Policy.Engine
  alias Relay.Policy.Fixture

  @classes [:action_required, :transactional, :operational, :social, :marketing]
  @lockable [:action_required, :transactional, :operational]
  @channels [
    :push,
    :web_push,
    :email,
    :sms,
    :voice,
    :whatsapp,
    :slack,
    :teams,
    :telegram,
    :discord,
    :in_app,
    :webhook
  ]

  @matrix %{
    action_required: %{push: :on, email: :on, sms: :off, whatsapp: :off, in_app: :on},
    transactional: %{push: :on, email: :on, sms: :on, whatsapp: :off, in_app: :on},
    operational: %{push: :on, email: :on, sms: :off, whatsapp: :off, in_app: :on},
    social: %{push: :on, email: :off, sms: :off, whatsapp: :off, in_app: :on},
    marketing: %{push: :off, email: :off, sms: :off, whatsapp: :off, in_app: :on}
  }
  @columns %{
    push: :push,
    web_push: :push,
    email: :email,
    sms: :sms,
    voice: :sms,
    whatsapp: :whatsapp,
    slack: :whatsapp,
    teams: :whatsapp,
    telegram: :whatsapp,
    discord: :whatsapp,
    in_app: :in_app,
    webhook: :in_app
  }

  defp snapshot(changes), do: Fixture.snapshot(changes)

  defp evaluate(changes), do: changes |> snapshot() |> Engine.evaluate()

  defp assert_at(%DateTime{} = actual, %DateTime{} = expected),
    do: assert(DateTime.compare(actual, expected) == :eq, "#{actual} is not #{expected}")

  defp sendable(class, channel, locked, pref) do
    [
      channel: channel,
      notification: [message_class: class],
      category: [locked: locked],
      consent: %{state: :active, ref: "c1"},
      preferences: [category_channel: pref]
    ]
  end

  defp quiet(from, to), do: [%{days: [1, 2, 3, 4, 5, 6, 7], from: from, to: to}]

  defp weekdays, do: [%{days: [1, 2, 3, 4, 5], from: ~T[09:00:00], to: ~T[18:00:00]}]

  defp capped(changes) do
    base = [
      channel: :push,
      target: [platform: :android],
      notification: [message_class: :marketing],
      preferences: [category_channel: :opt_in],
      frequency: %{global: %{count: 12, free_at: ~U[2026-11-02 13:00:00Z]}, policy: nil}
    ]

    evaluate(base ++ changes)
  end

  describe "PC-8 PC-12 PC-14 filters by class, channel, preference and lock" do
    test "PC-14: every class × channel × value × lock cell decides as the default matrix says" do
      for class <- @classes,
          channel <- @channels,
          locked <- if(class in @lockable, do: [true, false], else: [false]),
          pref <- [:opt_in, :opt_out, :unset] do
        result = evaluate(sendable(class, channel, locked, pref))
        default = @matrix |> Map.fetch!(class) |> Map.fetch!(Map.fetch!(@columns, channel))

        expected =
          cond do
            locked -> :send
            pref == :opt_in -> :send
            pref == :opt_out -> {:skip, "preference.category_channel"}
            default == :on -> :send
            true -> {:skip, "preference.category_default"}
          end

        case expected do
          :send ->
            assert {:send, _info} = result, inspect({class, channel, locked, pref, result})

          {:skip, rule_id} ->
            assert {:skip, :preference_off, ^rule_id, %{level: "category_channel"}} = result,
                   inspect({class, channel, locked, pref, result})
        end
      end
    end

    test "PC-6: security is locked and system has no preference surface: no value filters them" do
      for class <- [:security, :system], channel <- @channels, pref <- [:opt_out, :unset] do
        result =
          evaluate(
            channel: channel,
            notification: [message_class: class],
            category: [locked: class == :security],
            preferences: [category_channel: pref, channel: pref, workflow: pref, scope_key: pref]
          )

        assert {:send, _info} = result, inspect({class, channel, pref, result})
      end
    end

    test "PC-8 3a: the tenant's category switch filters an unlocked category with level tenant" do
      assert {:skip, :preference_off, "preference.tenant_category", detail} =
               evaluate(category: [enabled: false, subtenant_override: true])

      assert detail == %{level: "tenant", subtenant_override: true}

      assert {:send, _} = evaluate(category: [enabled: false, locked: true])

      assert {:skip, :preference_off, "preference.tenant_category", _} =
               evaluate(notification: [message_class: :system], category: [enabled: false])
    end

    test "PC-12: the levels combine with AND and the detail names the closing level" do
      for {level, rule_id} <- [
            channel: "preference.channel",
            workflow: "preference.workflow",
            scope_key: "preference.scope_key"
          ] do
        assert {:skip, :preference_off, ^rule_id, %{level: name}} =
                 evaluate(preferences: [{:category_channel, :opt_in}, {level, :opt_out}])

        assert name == Atom.to_string(level)
      end

      assert {:send, _} =
               evaluate(
                 preferences: [category_channel: :opt_in, channel: :opt_in, workflow: :opt_in]
               )
    end

    test "PC-12: a scope_key value overrides the category record of the same category" do
      assert {:send, _} = evaluate(preferences: [category_channel: :opt_out, scope_key: :opt_in])

      assert {:skip, :preference_off, "preference.scope_key", %{level: "scope_key"}} =
               evaluate(preferences: [category_channel: :opt_in, scope_key: :opt_out])

      assert {:skip, :preference_off, "preference.channel", _} =
               evaluate(preferences: [scope_key: :opt_in, channel: :opt_out])
    end

    test "PC-14: a tenant category default replaces the class default" do
      assert {:skip, :preference_off, "preference.category_default", detail} =
               evaluate(category: [channel_defaults: %{email: :off}])

      assert detail == %{level: "category_channel", source: :category_default}

      assert {:send, _} =
               evaluate(
                 channel: :sms,
                 notification: [message_class: :operational],
                 category: [channel_defaults: %{sms: :on}]
               )
    end

    test "PC-14 PC-54 PC-58 (3): marketing stays off on consent channels and non-Android push" do
      for channel <- [:email, :sms, :voice, :whatsapp] do
        assert {:skip, :preference_off, "preference.category_default", detail} =
                 evaluate(
                   channel: channel,
                   notification: [message_class: :marketing],
                   consent: %{state: :active, ref: "c1"},
                   category: [channel_defaults: %{channel => :on}]
                 )

        assert detail.source == :class_default
      end

      for platform <- [:ios, :web, nil] do
        assert {:skip, :preference_off, "preference.category_default", _} =
                 evaluate(
                   channel: :push,
                   target: [platform: platform],
                   notification: [message_class: :marketing],
                   category: [channel_defaults: %{push: :on}]
                 )
      end

      assert {:send, _} =
               evaluate(
                 channel: :push,
                 target: [platform: :android],
                 notification: [message_class: :marketing],
                 category: [channel_defaults: %{push: :on}]
               )

      assert {:send, _} =
               evaluate(
                 channel: :slack,
                 notification: [message_class: :marketing],
                 category: [channel_defaults: %{slack: :on}]
               )
    end
  end

  describe "PC-8 INV-15 gates" do
    test "PC-8: each gate decides with its rule and nothing it covers is sent" do
      cases = [
        {[tenant_suspended: true], :tenant_suspended, "tenant.suspended"},
        {[suppression: %{reason: :hard_bounce, ref: "s1"}], :suppressed_address,
         "suppression.address"},
        {[target: [address: :absent]], :no_address, "channel.no_address"},
        {[target: [address: :disabled]], :no_address, "channel.address_disabled"},
        {[channel: :push, target: [permission: :denied]], :no_permission,
         "channel.no_permission"},
        {[notification: [scope: :mismatch]], :scope_mismatch, "scope.mismatch"}
      ]

      for {changes, reason, rule_id} <- cases do
        assert {:skip, ^reason, ^rule_id, _detail} = evaluate(changes), rule_id
      end
    end

    test "PC-16: a denied OS permission is a gate only on push channels" do
      assert {:send, _} = evaluate(target: [permission: :denied])

      assert {:skip, :no_permission, "channel.no_permission", %{permission: :denied}} =
               evaluate(channel: :web_push, target: [permission: :denied])
    end

    test "PC-8 1b: the suppression detail carries its reason and record" do
      assert {:skip, :suppressed_address, "suppression.address", detail} =
               evaluate(suppression: %{reason: :complaint, ref: "sup_1"})

      assert detail == %{suppression_reason: :complaint, suppression_ref: "sup_1"}
    end

    test "TN-40: a kill switch pauses the delivery with its own rule" do
      id = Fixture.delivery_id()

      assert {:pause, "killswitch.paused_until", %{kill_switch_id: ^id}} =
               evaluate(kill_switch: {:pause, id, "killswitch.paused_until"})
    end

    test "PC-58 (3): marketing on email, SMS, voice and WhatsApp needs ACTIVE consent" do
      for channel <- [:email, :sms, :voice, :whatsapp] do
        for {state, reason, rule_id} <- [
              {:none, :consent_missing, "consent.missing"},
              {:pending, :consent_missing, "consent.missing"},
              {:expired, :consent_missing, "consent.expired"},
              {:revoked, :consent_revoked, "consent.revoked"}
            ] do
          assert {:skip, ^reason, ^rule_id, %{consent_ref: "c9"}} =
                   evaluate(
                     channel: channel,
                     notification: [message_class: :marketing],
                     preferences: [category_channel: :opt_in],
                     consent: %{state: state, ref: "c9"}
                   ),
                 "#{channel} #{state}"
        end
      end
    end

    test "PC-43 PC-58 (3): marketing push and in-app need no consent, but a refusal still stops them" do
      for channel <- [:push, :in_app] do
        changes = [
          channel: channel,
          notification: [message_class: :marketing],
          preferences: [category_channel: :opt_in]
        ]

        assert {:send, _} = evaluate(changes ++ [consent: %{state: :none, ref: nil}])

        assert {:skip, :consent_revoked, "consent.revoked", _} =
                 evaluate(changes ++ [consent: %{state: :revoked, ref: "c2"}])
      end
    end

    test "X-21: transactional and operational ask no consent" do
      for class <- [:transactional, :operational] do
        assert {:send, _} =
                 evaluate(
                   channel: :email,
                   notification: [message_class: class],
                   consent: %{state: :revoked, ref: "c3"}
                 )
      end
    end

    test "PC-51 INV-23: OTP subtypes keep to their channels" do
      for channel <- @channels -- [:sms, :whatsapp, :voice] do
        assert {:skip, :channel_policy, "channel_policy.otp_channel_forbidden", _} =
                 evaluate(
                   channel: channel,
                   notification: [message_class: :security, security_subtype: :otp_oob],
                   category: [locked: true]
                 )
      end

      verification = [message_class: :security, security_subtype: :email_verification]

      for channel <- @channels -- [:email] do
        assert {:skip, :channel_policy, "channel_policy.email_verification_only", _} =
                 evaluate(channel: channel, notification: verification, category: [locked: true])
      end

      for channel <- [:sms, :whatsapp, :voice] do
        assert {:send, _} =
                 evaluate(
                   channel: channel,
                   notification: [message_class: :security, security_subtype: :otp_oob],
                   category: [locked: true]
                 )
      end
    end

    test "PC-8 1a–1f: the first gate in order decides" do
      assert {:pause, "killswitch.off", _} =
               evaluate(
                 kill_switch: {:pause, Fixture.delivery_id(), "killswitch.off"},
                 tenant_suspended: true,
                 suppression: %{reason: :manual, ref: "s"},
                 notification: [scope: :mismatch]
               )

      assert {:skip, :suppressed_address, _, _} =
               evaluate(
                 suppression: %{reason: :manual, ref: "s"},
                 target: [address: :absent],
                 notification: [scope: :mismatch]
               )

      assert {:skip, :no_address, _, _} =
               evaluate(target: [address: :absent], notification: [scope: :mismatch])
    end

    property "INV-15 PC-11: no lock, class, priority or preference passes a gate" do
      gates =
        member_of([
          [kill_switch: {:pause, Fixture.delivery_id(), "killswitch.off"}],
          [tenant_suspended: true],
          [suppression: %{reason: :hard_bounce, ref: "s"}],
          [target: [address: :absent]],
          [target: [address: :disabled]],
          [notification: [scope: :mismatch]]
        ])

      check all gate <- gates,
                class <- member_of([:security, :system | @classes]),
                channel <- member_of(@channels),
                locked <- boolean(),
                priority <- member_of([nil, :low, :normal, :high]),
                pref <- member_of([:opt_in, :opt_out, :unset]),
                consent <- member_of([:none, :active, :revoked]) do
        changes = [
          channel: channel,
          notification: [message_class: class, priority: priority],
          category: [locked: locked or class == :security],
          preferences: [category_channel: pref, channel: pref, workflow: pref],
          consent: %{state: consent, ref: "c"}
        ]

        result = evaluate(changes ++ gate)

        assert elem(result, 0) in [:skip, :pause], inspect(result)
        refute match?({:skip, :preference_off, _, _}, result)
      end
    end
  end

  describe "INV-43 INV-45 unreadable inputs" do
    test "INV-43: an unreadable gate input stops the evaluation without a decision" do
      cases = [
        {[kill_switch: :unreadable], :kill_switch},
        {[kill_switch: {:hold, "killswitch.state_unknown"}], :kill_switch},
        {[kill_switch: {:pause, Fixture.delivery_id(), "quality.paused"}], :kill_switch},
        {[tenant_suspended: :unreadable], :tenant_suspended},
        {[suppression: :unreadable], :suppression},
        {[target: :unreadable], :target},
        {[notification: [scope: :unreadable]], :scope},
        {[channel: :push, notification: [message_class: :marketing], consent: :unreadable],
         :consent}
      ]

      for {changes, input} <- cases do
        assert {:error, {:input_unavailable, ^input}} = evaluate(changes), inspect(input)
      end
    end

    test "INV-43: a filter or shaper input that is needed and unreadable fails closed" do
      assert {:error, {:input_unavailable, :category}} = evaluate(category: :unreadable)
      assert {:error, {:input_unavailable, :preferences}} = evaluate(preferences: :unreadable)
      assert {:error, {:input_unavailable, :profile}} = evaluate(profile: :unreadable)

      assert {:error, {:input_unavailable, :time_zone}} =
               evaluate(tenant_time_zone: :unreadable, profile: [time_zone: nil])

      assert {:error, {:input_unavailable, :time_zone}} =
               evaluate(tenant_time_zone: "Mars/Olympus", profile: [time_zone: nil])
    end

    test "INV-43: an input the decision does not need may be unreadable" do
      assert {:send, _} = evaluate(consent: :unreadable)
      assert {:send, _} = evaluate(preferences: :unreadable, category: [locked: true])

      assert {:send, _} =
               evaluate(
                 notification: [message_class: :security],
                 category: :unreadable,
                 preferences: :unreadable,
                 profile: :unreadable
               )
    end

    test "INV-45: an unavailable frequency counter fails open and still asks to record" do
      assert {:send, %{frequency: :unavailable, counters: [%{kind: :global}]}} =
               evaluate(
                 channel: :push,
                 notification: [message_class: :operational],
                 frequency: :unavailable
               )

      assert {:send, %{frequency: :unavailable}} =
               evaluate(
                 channel: :push,
                 notification: [message_class: :operational],
                 frequency: %{global: nil, policy: nil}
               )
    end
  end

  describe "PC-45 PC-46 quiet hours and deferral" do
    test "PC-45: quiet hours defer an operational push to the end of the range, across midnight" do
      assert {:defer, :quiet_hours, "quiet_hours.deferred", until, detail} =
               evaluate(
                 now: ~U[2026-11-02 20:30:00Z],
                 channel: :push,
                 notification: [message_class: :operational],
                 profile: [quiet_hours: quiet(~T[22:00:00], ~T[07:00:00])]
               )

      assert_at(until, ~U[2026-11-03 04:00:00Z])
      assert detail.timezone == "Europe/Istanbul"
      assert detail.timezone_source == :profile
      assert detail.local_time == "2026-11-02T23:30:00"
    end

    test "PC-45: quiet hours apply to interrupting channels, to email only when chosen, never to in-app or webhook" do
      quiet = [quiet_hours: quiet(~T[14:00:00], ~T[16:00:00])]

      for channel <- @channels -- [:email, :in_app, :webhook] do
        assert {:defer, :quiet_hours, _, _, _} =
                 evaluate(
                   channel: channel,
                   notification: [message_class: :transactional],
                   category: [channel_defaults: %{channel => :on}],
                   profile: quiet
                 ),
               "#{channel}"
      end

      for channel <- [:email, :in_app, :webhook] do
        assert {:send, _} = evaluate(channel: channel, profile: quiet), "#{channel}"
      end

      assert {:defer, :quiet_hours, _, _, _} =
               evaluate(profile: [{:email_in_quiet_hours, true} | quiet])

      assert {:send, _} =
               evaluate(channel: :in_app, profile: [{:email_in_quiet_hours, true} | quiet])
    end

    test "PC-45 INV-24 PC-53: security, OTP, action_required and system are never deferred" do
      profile = [
        quiet_hours: quiet(~T[00:00:00], ~T[00:00:00]),
        schedule: [%{days: [6], from: ~T[09:00:00], to: ~T[10:00:00]}],
        dnd_until: ~U[2026-11-09 00:00:00Z]
      ]

      for {class, subtype} <- [
            security: nil,
            security: :otp_oob,
            action_required: nil,
            system: nil
          ] do
        assert {:send, %{frequency: :exempt}} =
                 evaluate(
                   channel: :sms,
                   notification: [message_class: class, security_subtype: subtype],
                   category: [locked: class == :security or class == :action_required],
                   profile: profile
                 ),
               "#{class} #{subtype}"
      end
    end

    test "PC-46: a deferral that finds no allowed instant before expires_at expires" do
      assert {:expire, "expiry.no_window", detail} =
               evaluate(
                 now: ~U[2026-11-02 20:30:00Z],
                 channel: :push,
                 notification: [expires_at: ~U[2026-11-03 02:00:00Z]],
                 profile: [quiet_hours: quiet(~T[22:00:00], ~T[07:00:00])]
               )

      assert detail.deferred_by == "quiet_hours.deferred"
    end

    test "PC-46: a range that never ends within eight days expires the delivery" do
      assert {:expire, "expiry.no_window", _} =
               evaluate(
                 channel: :push,
                 notification: [expires_at: nil],
                 profile: [quiet_hours: quiet(~T[00:00:00], ~T[00:00:00])]
               )
    end

    test "PC-49 WF-38: a delivery at or past expires_at expires, security included" do
      for class <- [:security, :transactional, :marketing] do
        assert {:expire, "expiry.expires_at", %{expires_at: _}} =
                 evaluate(
                   channel: :in_app,
                   notification: [message_class: class, expires_at: Fixture.now()],
                   category: [locked: class == :security]
                 )
      end
    end

    test "PC-58 (5): the weekly availability schedule defers to the next available start" do
      assert {:defer, :schedule, "schedule.deferred", until, _} =
               evaluate(
                 now: ~U[2026-11-07 07:00:00Z],
                 channel: :push,
                 notification: [expires_at: ~U[2026-11-12 00:00:00Z]],
                 profile: [schedule: weekdays()]
               )

      assert_at(until, ~U[2026-11-09 06:00:00Z])
    end

    test "PC-8 3e: action_required outside the schedule is filtered, unless locked" do
      changes = [
        now: ~U[2026-11-07 07:00:00Z],
        channel: :push,
        notification: [message_class: :action_required, expires_at: ~U[2026-11-08 00:00:00Z]],
        profile: [schedule: weekdays()]
      ]

      assert {:skip, :preference_off, "preference.schedule", %{level: "schedule"}} =
               evaluate(changes)

      assert {:send, _} = evaluate(changes ++ [category: [locked: true]])
    end

    test "WF-41 5: dnd_until defers to the next minute after it" do
      assert {:defer, :dnd, "dnd.deferred", until, _} =
               evaluate(channel: :push, profile: [dnd_until: ~U[2026-11-02 13:10:30Z]])

      assert_at(until, ~U[2026-11-02 13:11:00Z])
    end

    test "PC-58 (5): the earliest instant clears every constraint at once" do
      assert {:defer, :quiet_hours, "quiet_hours.deferred", until, _} =
               evaluate(
                 now: ~U[2026-11-02 20:30:00Z],
                 channel: :push,
                 profile: [
                   quiet_hours: quiet(~T[22:00:00], ~T[07:00:00]),
                   dnd_until: ~U[2026-11-03 05:00:00Z]
                 ]
               )

      assert_at(until, ~U[2026-11-03 05:00:00Z])
    end

    test "WF-42: the release jitter is deterministic, inside the spread and never leaves the allowed stretch" do
      base = [
        now: ~U[2026-11-02 20:30:00Z],
        channel: :push,
        jitter_spread_ms: 600_000,
        profile: [quiet_hours: quiet(~T[22:00:00], ~T[07:00:00])]
      ]

      assert {:defer, _, _, first, _} = evaluate(base)
      assert {:defer, _, _, ^first, _} = evaluate(base)
      offset = DateTime.diff(first, ~U[2026-11-03 04:00:00Z], :millisecond)
      assert offset >= 0 and offset < 600_000

      expected =
        Relay.Jitter.release(
          Fixture.tenant_id(),
          :live,
          Fixture.recipient_id(),
          "2026-11-03T07:00:00",
          600_000
        )

      assert offset == expected

      ranges = quiet(~T[22:00:00], ~T[07:00:00]) ++ quiet(~T[07:01:00], ~T[08:00:00])
      assert {:defer, _, _, until, _} = evaluate(Keyword.put(base, :profile, quiet_hours: ranges))
      assert DateTime.diff(until, ~U[2026-11-03 04:00:00Z], :millisecond) in 0..59_999
    end
  end

  describe "PC-48 tenant time zone window" do
    test "PC-48: marketing and social with the tenant's zone wait for 10:00–18:00 there" do
      for {class, channel} <- [marketing: :push, social: :in_app] do
        assert {:defer, :tenant_timezone_window, rule_id, until, detail} =
                 evaluate(
                   now: ~U[2026-11-02 05:00:00Z],
                   channel: channel,
                   target: [platform: :android],
                   notification: [message_class: class],
                   preferences: [category_channel: :opt_in],
                   profile: [time_zone: nil]
                 )

        assert rule_id == "tenant_timezone_window.deferred"
        assert_at(until, ~U[2026-11-02 07:00:00Z])
        assert detail.timezone_source == :tenant_default
      end

      assert {:defer, :tenant_timezone_window, _, until, _} =
               evaluate(
                 now: ~U[2026-11-02 16:00:00Z],
                 channel: :in_app,
                 notification: [message_class: :social],
                 profile: [time_zone: nil]
               )

      assert_at(until, ~U[2026-11-03 07:00:00Z])
    end

    test "PC-48: the window does not apply when the zone is the recipient's own, nor to other classes" do
      assert {:send, %{timezone_source: :profile}} =
               evaluate(
                 now: ~U[2026-11-02 05:00:00Z],
                 channel: :in_app,
                 notification: [message_class: :social]
               )

      assert {:send, %{timezone_source: :tenant_default}} =
               evaluate(
                 now: ~U[2026-11-02 05:00:00Z],
                 channel: :push,
                 notification: [message_class: :operational],
                 profile: [time_zone: nil]
               )

      assert {:send, %{timezone_source: :device}} =
               evaluate(
                 now: ~U[2026-11-02 05:00:00Z],
                 channel: :in_app,
                 notification: [message_class: :social],
                 profile: [time_zone: nil],
                 device_time_zone: "Europe/Berlin"
               )
    end
  end

  describe "PC-50 frequency cap" do
    test "PC-50: the global cap of 12 drops marketing by default" do
      assert {:skip, :frequency_capped, "frequency.dropped", %{counter: :global}} = capped([])
    end

    test "PC-50: the category fate decides what a capped delivery becomes" do
      assert {:defer, :frequency_capped, "frequency.deferred", until, %{counter: :global}} =
               capped(category: [frequency: %{limit: nil, window_ms: nil, fate: :defer}])

      assert_at(until, ~U[2026-11-02 13:00:00Z])

      assert {:defer, :frequency_capped, "frequency.digest", _, _} =
               capped(category: [frequency: %{limit: nil, window_ms: nil, fate: :digest}])

      assert {:skip, :frequency_capped, "frequency.inbox_only", _} =
               capped(category: [frequency: %{limit: nil, window_ms: nil, fate: :inbox_only}])
    end

    test "PC-50: operational defers and social digests by default" do
      assert {:defer, :frequency_capped, "frequency.deferred", _, _} =
               capped(notification: [message_class: :operational])

      assert {:defer, :frequency_capped, "frequency.digest", _, _} =
               capped(notification: [message_class: :social])
    end

    test "PC-46 PC-50: a deferred capped delivery still waits for the end of quiet hours" do
      assert {:defer, :frequency_capped, "frequency.deferred", until, _} =
               capped(
                 notification: [message_class: :operational],
                 profile: [quiet_hours: quiet(~T[16:00:00], ~T[17:00:00])]
               )

      assert_at(until, ~U[2026-11-02 14:00:00Z])
    end

    test "PC-50: the category × channel policy caps on its own counter, also on in-app" do
      policy = %{limit: 3, window_ms: 3_600_000, fate: :drop}

      assert {:skip, :frequency_capped, "frequency.dropped", %{counter: :policy}} =
               capped(
                 category: [frequency: policy],
                 frequency: %{global: Fixture.zero(), policy: %{count: 3, free_at: nil}}
               )

      assert {:send, %{counters: [%{kind: :global}, %{kind: :policy, limit: 3}]}} =
               capped(
                 category: [frequency: policy],
                 frequency: %{global: Fixture.zero(), policy: %{count: 2, free_at: nil}}
               )

      assert {:send, %{counters: [%{kind: :policy, category: "orders", channel: :in_app}]}} =
               capped(
                 channel: :in_app,
                 category: [frequency: %{policy | fate: :inbox_only}],
                 frequency: %{global: nil, policy: %{count: 3, free_at: nil}}
               )
    end

    test "PC-50: the global cap counts only external channels" do
      for channel <- [:in_app, :webhook] do
        assert {:send, %{counters: [], frequency: :exempt}} =
                 capped(channel: channel, category: [channel_defaults: %{webhook: :on}])
      end
    end

    test "PC-50: a tenant may lower the global cap but not raise it" do
      assert {:skip, :frequency_capped, _, _} =
               capped(global_cap: 5, frequency: %{global: %{count: 5, free_at: nil}, policy: nil})

      assert {:send, %{counters: [%{kind: :global, limit: 5}]}} =
               capped(global_cap: 5, frequency: %{global: %{count: 4, free_at: nil}, policy: nil})

      assert {:skip, :frequency_capped, _, _} = capped(global_cap: 20)
    end

    test "PC-50: security, action_required, transactional and system are not capped" do
      for class <- [:security, :action_required, :transactional, :system] do
        assert {:send, %{counters: [], frequency: :exempt}} =
                 capped(
                   notification: [message_class: class],
                   category: [locked: class == :security]
                 )
      end
    end
  end

  describe "PC-58 (7) API-22 priority" do
    test "PC-58 (7): the send decision carries the priority clamped to the class ceiling" do
      cases = [
        {:security, :high, :high, false},
        {:transactional, :high, :high, false},
        {:operational, :high, :normal, true},
        {:marketing, :high, :normal, true},
        {:system, :normal, :low, true},
        {:system, nil, :low, false},
        {:social, nil, :normal, false},
        {:social, :low, :low, false}
      ]

      for {class, requested, priority, clamped} <- cases do
        assert {:send, %{priority: ^priority, priority_clamped: ^clamped}} =
                 evaluate(
                   channel: :in_app,
                   notification: [message_class: class, priority: requested],
                   category: [locked: class == :security]
                 ),
               inspect({class, requested})
      end
    end
  end

  test "PC-58 (6): counters/1 lists the counters to read before the evaluation" do
    snapshot =
      snapshot(
        channel: :sms,
        notification: [message_class: :operational],
        category: [frequency: %{limit: 2, window_ms: 60_000, fate: nil}]
      )

    assert [%{kind: :global, limit: 12, window_ms: 86_400_000}, %{kind: :policy, limit: 2}] =
             Engine.counters(snapshot)

    assert Engine.counters(snapshot(category: :unreadable)) == []
  end
end
