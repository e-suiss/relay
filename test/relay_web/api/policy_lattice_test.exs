defmodule RelayWeb.Api.PolicyLatticeTest do
  use Relay.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Relay.Repo
  alias Relay.Tenancy.KillSwitch
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @actor ["operator", "acc_op_1", "acc_op_1", nil]
  @operator %{kind: :installation_operator, ref: "ops@example"}
  @zone "Europe/Istanbul"
  @days ~w(mon tue wed thu fri sat sun)

  @create "SELECT * FROM relay_fn.category_create($1, $2, $3, $4, $5, $6, $7, $8::text::interval, $9, $10::text::interval, $11, false, NULL, $12, $13, $14, $15, $16)"
  @preference "SELECT * FROM relay_fn.preference_set($1, $2, $3, $4, $5, $6, 'subscriber', 'acc_user_1')"
  @profile "SELECT * FROM relay_fn.preference_profile_put($1, $2, '[]', NULL, false, '{}', 'subscriber', NULL)"
  @consent "SELECT * FROM relay_fn.consent_record($1, $2, NULL, 'email', $3, NULL, NULL, 'access', $4, $5, NULL, NULL, NULL, NULL, 'access', $6)"
  @suppress "SELECT * FROM relay_fn.suppression_add($1, 'email', $2, $3, NULL, 'hard_bounce', NULL, $4, $5, $6, $7, $8)"

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp category!(scope, key, class, opts \\ []) do
    [["created", _id, 1]] =
      sql!(scope, @create, [
        Relay.Id.generate(),
        key,
        "Category " <> key,
        class,
        Keyword.get(opts, :locked, false),
        Keyword.get(opts, :enabled, true),
        Keyword.get(opts, :defaults, %{}),
        opts[:expires_in],
        opts[:limit],
        opts[:window],
        opts[:fate],
        TenantFixture.digest() | @actor
      ])

    key
  end

  defp workflow!(scope, token, key, category, class, channels) do
    F.workflow!(scope, token, key, category: category, message_class: class, channels: channels)
  end

  defp subscriber!(token, fields \\ %{}) do
    external_id = "user-" <> TenantFixture.random()

    body =
      Map.merge(
        %{"external_id" => external_id, "email" => "ayse@example.com", "timezone" => @zone},
        fields
      )

    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    external_id
  end

  defp device!(token, external_id, permission \\ "granted") do
    body = %{
      "platform" => "fcm",
      "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
      "app" => "com.example.shop",
      "permission" => permission
    }

    F.body(F.request(:post, "/v1/subscribers/#{external_id}/devices", token, body), 201)
    external_id
  end

  defp recipient_id(scope, external_id) do
    {:ok, %{"_id" => id}} = Relay.Subscribers.fetch(scope, external_id)
    id
  end

  defp preference!(scope, external_id, level, key, channel, value) do
    recipient = recipient_id(scope, external_id)
    params = [Relay.Id.generate(), recipient, level, key, channel, value]
    [["set", _id, _version]] = sql!(scope, @preference, params)
  end

  defp quiet_now! do
    now = DateTime.shift_zone!(Relay.Clock.utc_now(), @zone)
    from = DateTime.add(now, -3_600)
    to = DateTime.add(now, 7_200)
    range = %{"day" => Enum.at(@days, Date.day_of_week(from) - 1), "start" => hhmm(from)}
    {[Map.put(range, "end", hhmm(to))], %{to | second: 0, microsecond: {0, 0}}}
  end

  defp hhmm(at), do: at |> DateTime.to_time() |> Time.to_iso8601() |> binary_part(0, 5)

  defp quiet!(scope, external_id) do
    {ranges, ends} = quiet_now!()
    recipient = recipient_id(scope, external_id)
    [[result, _version]] = sql!(scope, @profile, [recipient, ranges])
    assert result in ["created", "updated"]
    DateTime.shift_zone!(ends, "Etc/UTC")
  end

  defp consent!(scope, external_id, status, sequence) do
    recipient = recipient_id(scope, external_id)
    now = Relay.Clock.utc_now()
    params = [Relay.Id.generate(), recipient, status, sequence, now, "evt_#{sequence}"]
    [["recorded", _id]] = sql!(scope, @consent, params)
  end

  defp suppress!(scope, external_id) do
    recipient = recipient_id(scope, external_id)

    [[bidx, key_id]] =
      sql!(
        scope,
        """
        SELECT address_bidx, address_bidx_key_id FROM relay.recipient_addresses
        WHERE recipient_id = $1 AND kind = 'email' AND state = 'active'
        """,
        [recipient]
      )

    params = [Relay.Id.generate(), bidx, key_id, TenantFixture.digest() | @actor]
    [["added", _id]] = sql!(scope, @suppress, params)
  end

  defp send!(token, workflow, to, extra \\ %{}) do
    data = %{"order" => "A-1"}
    body = Map.merge(%{"workflow" => workflow, "to" => [to], "data" => data}, extra)
    F.body(F.request(:post, "/v1/events", token, body), 202)
  end

  defp deliveries(token, accepted) do
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    F.body(F.request(:get, path, token), 200)["data"]
  end

  defp delivery!(token, workflow, to, extra \\ %{}) do
    [delivery] = deliveries(token, send!(token, workflow, to, extra))
    delivery
  end

  defp internal(%{"id" => id}) do
    {:ok, delivery_id} = Relay.ExternalId.decode(id, ["dlv"])
    delivery_id
  end

  defp ledger(scope, delivery, type) do
    sql =
      "SELECT detail FROM relay.delivery_events WHERE delivery_id = $1 AND event_type = $2 ORDER BY received_at, id"

    for [detail] <- sql!(scope, sql, [internal(delivery), type]), do: detail
  end

  defp decision(scope, delivery) do
    [row] =
      sql!(
        scope,
        "SELECT decision, decision_rule_id, deferred_until FROM relay.deliveries WHERE id = $1",
        [internal(delivery)]
      )

    row
  end

  defp suppressed(scope, delivery) do
    sql = "SELECT payload FROM relay.outbox_events WHERE event_type = 'notification.suppressed'"
    id = Relay.Id.to_string(internal(delivery))
    for [payload] <- sql!(scope, sql, []), payload["delivery_id"] == id, do: payload
  end

  defp run!(scope, delivery) do
    id = Relay.Id.to_string(internal(delivery))
    args = Map.put(Relay.Scope.to_job_args(scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
  end

  defp attach(event) do
    ref = make_ref()
    pid = self()
    handler = "policy-lattice-test-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, meta, _config -> send(pid, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp with_counter(options, fun) do
    previous = Application.get_env(:relay, Relay.Policy.Live)
    Application.put_env(:relay, Relay.Policy.Live, frequency_counter: options)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:relay, Relay.Policy.Live, previous),
        else: Application.delete_env(:relay, Relay.Policy.Live)
    end
  end

  defp await_valkey(0), do: flunk("Valkey is not reachable")

  defp await_valkey(n) do
    if Relay.Platform.Valkey.ping() == :ok do
      :ok
    else
      Process.sleep(50)
      await_valkey(n - 1)
    end
  end

  describe "PC-8 PC-12 PC-15 filters" do
    test "PC-9, PC-12: a preference off at each level skips the delivery with the closing level",
         ctx do
      category!(ctx.scope, "orders", "transactional")
      workflow!(ctx.scope, ctx.token, "order-shipped", "orders", "transactional", ["email"])
      category!(ctx.scope, "closed", "transactional", enabled: false)
      workflow!(ctx.scope, ctx.token, "closed-note", "closed", "transactional", ["email"])

      cases = [
        {"category_channel", "orders", "email", "preference.category_channel"},
        {"channel", nil, "email", "preference.channel"},
        {"workflow", "order-shipped", nil, "preference.workflow"}
      ]

      for {level, key, channel, rule} <- cases do
        external_id = subscriber!(ctx.token)
        preference!(ctx.scope, external_id, level, key, channel, "opt_out")
        delivery = delivery!(ctx.token, "order-shipped", external_id)

        assert %{"status" => "skipped", "reason" => "preference_off"} = delivery
        assert delivery["rule_id"] == rule

        assert [%{"level" => ^level, "rule_id" => ^rule}] =
                 ledger(ctx.scope, delivery, "delivery.skipped")

        assert F.delivery_jobs(delivery["id"]) == []
      end

      delivery = delivery!(ctx.token, "closed-note", subscriber!(ctx.token))
      assert delivery["rule_id"] == "preference.tenant_category"
      assert [%{"level" => "tenant"}] = ledger(ctx.scope, delivery, "delivery.skipped")
    end

    test "PC-13, PC-14: an unset cell falls to the class default; social email is off", ctx do
      category!(ctx.scope, "feed", "social")
      workflow!(ctx.scope, ctx.token, "mention", "feed", "social", ["email", "in_app"])

      accepted = send!(ctx.token, "mention", subscriber!(ctx.token))
      by_channel = Map.new(deliveries(ctx.token, accepted), &{&1["channel"], &1})

      assert by_channel["email"]["rule_id"] == "preference.category_default"
      assert by_channel["in_app"]["status"] == "queued"
    end

    test "PC-6, PC-8: a locked category passes the filters but never a gate", ctx do
      category!(ctx.scope, "account", "transactional", locked: true)
      workflow!(ctx.scope, ctx.token, "password-changed", "account", "transactional", ["email"])
      external_id = subscriber!(ctx.token)
      preference!(ctx.scope, external_id, "category_channel", "account", "email", "opt_out")

      sent = delivery!(ctx.token, "password-changed", external_id)
      assert %{"status" => "queued", "rule_id" => nil} = sent
      assert [_job] = F.delivery_jobs(sent["id"])

      suppress!(ctx.scope, external_id)
      gated = delivery!(ctx.token, "password-changed", external_id)

      assert %{"status" => "skipped", "reason" => "suppressed_address"} = gated
      assert gated["rule_id"] == "suppression.address"
    end
  end

  describe "PC-58 (3) PC-59 consent gates" do
    test "PC-58 (3), INV-18: marketing email needs ACTIVE consent; a revocation is its own rule",
         ctx do
      category!(ctx.scope, "news", "marketing")
      workflow!(ctx.scope, ctx.token, "newsletter", "news", "marketing", ["email"])
      ref = attach([:relay, :policy, :decision])

      missing = delivery!(ctx.token, "newsletter", subscriber!(ctx.token))
      assert %{"status" => "skipped", "reason" => "consent_missing"} = missing
      assert missing["rule_id"] == "consent.missing"
      assert_receive {^ref, %{count: 1}, %{decision: :skip, reason: "consent_missing"}}

      pending = subscriber!(ctx.token)
      consent!(ctx.scope, pending, "pending", 1)
      assert delivery!(ctx.token, "newsletter", pending)["rule_id"] == "consent.missing"

      revoked = subscriber!(ctx.token)
      consent!(ctx.scope, revoked, "revoked", 1)
      delivery = delivery!(ctx.token, "newsletter", revoked)
      assert %{"reason" => "consent_revoked", "rule_id" => "consent.revoked"} = delivery
    end

    test "INV-15, PC-11: no request field passes a gate", ctx do
      category!(ctx.scope, "news", "marketing")
      workflow!(ctx.scope, ctx.token, "newsletter", "news", "marketing", ["email"])

      extra = %{"priority" => "high", "channels" => ["email"], "dedup_key" => "flagged"}
      delivery = delivery!(ctx.token, "newsletter", subscriber!(ctx.token), extra)

      assert delivery["rule_id"] == "consent.missing"
      assert F.delivery_jobs(delivery["id"]) == []
    end

    test "DS-24: a skip announces notification.suppressed in the same transaction", ctx do
      category!(ctx.scope, "news", "marketing")
      workflow = workflow!(ctx.scope, ctx.token, "newsletter", "news", "marketing", ["email"])
      delivery = delivery!(ctx.token, "newsletter", subscriber!(ctx.token))

      assert [payload] = suppressed(ctx.scope, delivery)
      assert payload["rule_id"] == "consent.missing"
      assert payload["reason"] == "consent_missing"
      assert payload["channel"] == "email"
      version = workflow["published_version"]
      assert payload["workflow"] == %{"key" => "newsletter", "version" => version}
      assert is_binary(payload["notification_id"]) and is_binary(payload["recipient_id"])
    end
  end

  describe "PC-51 PC-53 security class" do
    test "PC-51, INV-23: an otp_oob subtype on email is a channel policy skip", ctx do
      category!(ctx.scope, "login", "security", locked: true)
      workflow!(ctx.scope, ctx.token, "login-code", "login", "security", ["email", "sms"])
      external_id = subscriber!(ctx.token, %{"phone" => "+905551112233"})
      expires = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 600))
      extra = %{"security_subtype" => "otp_oob", "expires_at" => expires}

      accepted = send!(ctx.token, "login-code", external_id, extra)
      by_channel = Map.new(deliveries(ctx.token, accepted), &{&1["channel"], &1})

      assert %{"status" => "skipped", "reason" => "otp_channel_forbidden"} = by_channel["email"]
      assert by_channel["email"]["rule_id"] == "channel_policy.otp_channel_forbidden"
      assert by_channel["sms"]["status"] == "queued"
      assert [_payload] = suppressed(ctx.scope, by_channel["email"])
    end

    test "PC-45, PC-53: security passes quiet hours that defer an operational push", ctx do
      category!(ctx.scope, "alerts", "security", locked: true)
      workflow!(ctx.scope, ctx.token, "new-device", "alerts", "security", ["push"])
      category!(ctx.scope, "ops", "operational")
      workflow!(ctx.scope, ctx.token, "maintenance", "ops", "operational", ["push"])
      external_id = device!(ctx.token, subscriber!(ctx.token))
      quiet!(ctx.scope, external_id)

      alert = delivery!(ctx.token, "new-device", external_id)
      assert %{"status" => "queued", "deferred_until" => nil} = alert
      assert ["send", nil, nil] = decision(ctx.scope, alert)

      notice = delivery!(ctx.token, "maintenance", external_id)
      assert %{"status" => "queued", "rule_id" => "quiet_hours.deferred"} = notice
      assert is_binary(notice["deferred_until"])
    end
  end

  describe "CH-28 CH-29 device targets" do
    test "CH-28: a push without a device or without a permitted device is skipped", ctx do
      category!(ctx.scope, "ops", "operational")
      workflow!(ctx.scope, ctx.token, "maintenance", "ops", "operational", ["push"])

      none = delivery!(ctx.token, "maintenance", subscriber!(ctx.token))
      assert %{"status" => "skipped", "rule_id" => "channel.no_address"} = none

      denied = device!(ctx.token, subscriber!(ctx.token), "denied")
      blocked = delivery!(ctx.token, "maintenance", denied)
      assert %{"status" => "skipped", "rule_id" => "channel.no_permission"} = blocked

      granted = device!(ctx.token, subscriber!(ctx.token))
      assert %{"status" => "queued"} = delivery!(ctx.token, "maintenance", granted)
    end

    test "CH-29: a provisional device takes marketing and social pushes only", ctx do
      category!(ctx.scope, "ops", "operational")
      workflow!(ctx.scope, ctx.token, "maintenance", "ops", "operational", ["push"])
      category!(ctx.scope, "friends", "social")
      workflow!(ctx.scope, ctx.token, "friend-joined", "friends", "social", ["push"])
      external_id = device!(ctx.token, subscriber!(ctx.token), "provisional")

      blocked = delivery!(ctx.token, "maintenance", external_id)
      assert %{"status" => "skipped", "rule_id" => "channel.no_permission"} = blocked

      assert %{"status" => "queued"} = delivery!(ctx.token, "friend-joined", external_id)
    end
  end

  describe "PC-46 PC-58 (5) DS-27 deferral" do
    test "PC-8, DS-27: a quiet hours deferral is passed again at deferred_until on the virtual clock",
         ctx do
      scope = ctx.tenant.test
      token = F.token(scope)
      category!(scope, "ops", "operational")
      workflow!(scope, token, "maintenance", "ops", "operational", ["push"])
      external_id = device!(token, subscriber!(token))
      ends = quiet!(scope, external_id)

      delivery = delivery!(token, "maintenance", external_id)
      assert %{"status" => "queued", "reason" => "quiet_hours"} = delivery
      assert ["defer", "quiet_hours.deferred", %DateTime{} = until] = decision(scope, delivery)
      assert DateTime.compare(until, ends) != :lt
      assert DateTime.diff(until, ends) <= 1_000

      assert [%{"rule_id" => "quiet_hours.deferred", "deferred_until" => _} = detail] =
               ledger(scope, delivery, "delivery.deferred")

      assert detail["timezone_source"] == "profile"
      assert suppressed(scope, delivery) == []

      step = DateTime.diff(until, Relay.Clock.business_now(scope), :millisecond) + 60_000

      assert {:ok, {:advanced, _offset, _now}} =
               Relay.Platform.VirtualClock.advance(
                 scope,
                 step,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )

      assert run!(scope, delivery) == {:snooze, 300}
      assert ["send", nil, nil] = decision(scope, delivery)
    end

    test "PC-46, PC-49: a deferral with no allowed instant before expires_at expires", ctx do
      category!(ctx.scope, "orders", "transactional")
      workflow!(ctx.scope, ctx.token, "order-out", "orders", "transactional", ["push"])
      external_id = device!(ctx.token, subscriber!(ctx.token))
      quiet!(ctx.scope, external_id)
      expires = DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 1_800))

      delivery = delivery!(ctx.token, "order-out", external_id, %{"expires_at" => expires})

      assert %{"status" => "expired", "rule_id" => "expiry.no_window"} = delivery
      assert [%{"reason" => "expired"}] = suppressed(ctx.scope, delivery)
      assert F.delivery_jobs(delivery["id"]) == []
    end
  end

  describe "PC-50 PC-58 (6) frequency" do
    @describetag :integration

    test "PC-50: a capped delivery meets its category's fate", ctx do
      await_valkey(100)

      with_counter([backend: __MODULE__.Unstarted], fn ->
        category!(ctx.scope, "deals", "marketing", limit: 1, window: "PT1H", fate: "drop")
        workflow!(ctx.scope, ctx.token, "deal", "deals", "marketing", ["in_app"])
        category!(ctx.scope, "promos", "marketing", limit: 1, window: "PT1H", fate: "defer")
        workflow!(ctx.scope, ctx.token, "promo", "promos", "marketing", ["in_app"])
        external_id = subscriber!(ctx.token)

        first = delivery!(ctx.token, "deal", external_id)
        assert first["status"] == "queued"
        assert run!(ctx.scope, first) == {:snooze, 300}

        dropped = delivery!(ctx.token, "deal", external_id)
        assert %{"status" => "skipped", "reason" => "frequency_capped"} = dropped
        assert dropped["rule_id"] == "frequency.dropped"

        promo = delivery!(ctx.token, "promo", external_id)
        assert run!(ctx.scope, promo) == {:snooze, 300}
        deferred = delivery!(ctx.token, "promo", external_id)

        assert %{"status" => "queued", "rule_id" => "frequency.deferred"} = deferred
        assert ["defer", "frequency.deferred", until] = decision(ctx.scope, deferred)
        assert DateTime.diff(until, Relay.Clock.utc_now()) > 3_000
      end)
    end

    test "INV-45, PC-50: an unreadable counter fails open and is counted", ctx do
      stub(Relay.ValkeyMock, :command, fn _command ->
        {:error, %Redix.ConnectionError{reason: :closed}}
      end)

      ref = attach([:relay, :frequency_counter, :unavailable])

      with_counter([backend: __MODULE__.Unstarted, adapter: Relay.ValkeyMock], fn ->
        category!(ctx.scope, "deals", "marketing", limit: 1, window: "PT1H", fate: "drop")
        workflow!(ctx.scope, ctx.token, "deal", "deals", "marketing", ["in_app"])
        external_id = subscriber!(ctx.token)

        capture_log(fn ->
          first = delivery!(ctx.token, "deal", external_id)
          assert first["status"] == "queued"
          assert run!(ctx.scope, first) == {:snooze, 300}
          assert delivery!(ctx.token, "deal", external_id)["status"] == "queued"
        end)
      end)

      assert_receive {^ref, %{count: 1}, %{op: :read}}
      assert_receive {^ref, %{count: 1}, %{op: :record}}
    end
  end

  describe "API-22 PC-58 (7) PC-58 (8)" do
    test "API-22, PC-58 (7): a priority above the class ceiling is clamped and stored", ctx do
      category!(ctx.scope, "ops", "operational")
      workflow!(ctx.scope, ctx.token, "maintenance", "ops", "operational", ["in_app"])

      accepted = send!(ctx.token, "maintenance", subscriber!(ctx.token), %{"priority" => "high"})
      assert [%{"code" => "priority_clamped", "pointer" => "/priority"}] = accepted["warnings"]

      {:ok, event_id} = Relay.ExternalId.decode(accepted["id"], ["evt"])
      priority = "SELECT priority FROM relay.events WHERE id = $1"
      assert [["normal"]] = sql!(ctx.scope, priority, [event_id])
    end

    test "PC-58 (8), DS-26: dry_run answers each channel's decision and opens nothing", ctx do
      scope = ctx.tenant.test
      token = F.token(scope)
      category!(scope, "orders", "transactional")
      workflow!(scope, token, "order-shipped", "orders", "transactional", ["email"])
      category!(scope, "news", "marketing")
      workflow!(scope, token, "newsletter", "news", "marketing", ["email", "in_app"])
      external_id = subscriber!(token)

      sent = send!(token, "order-shipped", external_id, %{"send_mode" => "dry_run"})
      assert [%{"decisions" => [send]}] = sent["notifications"]

      assert send == %{
               "channel" => "email",
               "decision" => "send",
               "reason" => nil,
               "rule_id" => nil,
               "deferred_until" => nil
             }

      assert deliveries(token, sent) == []

      news = send!(token, "newsletter", external_id, %{"send_mode" => "dry_run"})
      [%{"decisions" => decisions}] = news["notifications"]
      by_channel = Map.new(decisions, &{&1["channel"], &1})

      assert %{"decision" => "skip", "rule_id" => "consent.missing"} = by_channel["email"]
      assert by_channel["in_app"]["decision"] == "send"
      assert deliveries(token, news) == []
    end
  end

  describe "TN-40 TN-70 (2) resume through the lattice" do
    test "TN-40, PC-58 (2): a kill switch pause is resumed through the running lattice", ctx do
      category!(ctx.scope, "orders", "transactional")
      workflow!(ctx.scope, ctx.token, "order-shipped", "orders", "transactional", ["email"])
      later = DateTime.add(Relay.Clock.utc_now(), 3_600)
      spec = %{scope_kind: :tenant, scope: ctx.scope, reason: "incident 9", expires_at: later}
      {:ok, %{result: :engaged, id: kill_switch}} = KillSwitch.engage(spec, @operator)

      delivery = delivery!(ctx.token, "order-shipped", subscriber!(ctx.token))
      assert run!(ctx.scope, delivery) == :ok

      paused = "SELECT paused_at IS NOT NULL, pause_rule_id FROM relay.deliveries WHERE id = $1"
      assert [[true, "killswitch.off"]] = sql!(ctx.scope, paused, [internal(delivery)])

      held = %{reason: "ok", relax_approval: "CAB-1"}
      assert {:ok, %{resumed: 0, cancelled: 0}} = KillSwitch.resume(kill_switch, held, @operator)

      released = %{reason: "ok", relax_approval: "CAB-2"}
      assert {:ok, %{result: :released}} = KillSwitch.release(kill_switch, released, @operator)

      go = %{reason: "ok", relax_approval: "CAB-3", job: &Relay.Delivery.send_job/2}
      assert {:ok, %{resumed: 1, cancelled: 0}} = KillSwitch.resume(kill_switch, go, @operator)

      assert [[false, nil]] = sql!(ctx.scope, paused, [internal(delivery)])

      assert length(F.delivery_jobs(delivery["id"])) == 2
    end
  end
end
