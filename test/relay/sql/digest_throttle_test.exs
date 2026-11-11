defmodule Relay.Sql.DigestThrottleTest do
  use Relay.SqlCase, async: false

  @add "SELECT * FROM relay_fn.digest_item_add($1, $2, $3, $4, 'step', $5, $6, $7, $8, NULL, NULL, NULL, $9, 2678400000, $10, NULL, $11)"
  @plan "SELECT result, fire_at, timer_at FROM relay_fn.digest_window_plan($1, $2)"
  @fire "SELECT * FROM relay_fn.digest_window_fire($1)"
  @read "SELECT window_id, result FROM relay_fn.digest_read($1, $2)"
  @due "SELECT window_id FROM relay_fn.digest_due(100)"
  @hit "SELECT result, hit_count, repeated FROM relay_fn.throttle_hit($1, $2, $3, $4, NULL, NULL)"
  @reset "SELECT * FROM relay_fn.throttle_reset($1, $2, $3, $4, $5, $6)"
  @check "SELECT result, duplicate_of FROM relay_fn.content_dedup_check($1, $2)"
  @advance "SELECT * FROM relay_fn.virtual_clock_advance($1, $2, $3, $4, $5, $6)"
  @category "SELECT * FROM relay_fn.category_create($1, $2, $3, $4, false, true, '{}', NULL, NULL, NULL, NULL, false, $5, $6, $7, $8, $9)"
  @create "SELECT * FROM relay_fn.template_create($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)"
  @publish "SELECT * FROM relay_fn.template_publish($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)"
  @pin "SELECT relay_fn.delivery_plan_pin($1, $2, $3, $4, $5, $6)"
  @subject_key "SELECT * FROM relay_fn.subject_key_create($1, $2, $3, $4, $5)"
  @wrap "SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1 LIMIT 1"
  @record "SELECT relay_fn.delivery_render_record($1, $2, $3, $4, $5)"
  @skipped "SELECT decision_reason, decision_rule_id FROM relay.deliveries WHERE decision = 'skip' AND id = ANY($1)"
  @audit "SELECT action, target_id FROM relay_fn.audit_query($1, $2, $3, NULL, 10, $4, $5, $6, $7, $8)"
  @deadline "SELECT deadline_at - first_at <= interval '31 days' FROM relay.digest_windows WHERE id = $1"
  @variables %{"always" => ["order.id"], "conditional" => []}
  @measures %{"sms" => %{"tr" => %{"segments" => 1}}}
  @hour 3_600_000

  defp setup! do
    s = scenario!()
    others = for _ <- 1..4, do: notification!(s.recipient)
    Map.merge(s, %{key: digest(), notifications: [s.notification | others]})
  end

  defp add(s, notification, opts \\ []) do
    row(@add, [
      id(),
      id(),
      s.recipient,
      Keyword.get(opts, :key, s.key),
      Keyword.get(opts, :mode, "sliding"),
      Keyword.get(opts, :leading, "none"),
      Keyword.get(opts, :debounce, 30_000),
      Keyword.get(opts, :max_wait, 300_000),
      opts[:max_items],
      notification,
      opts[:actor]
    ])
  end

  defp due!(window) do
    row(@plan, [window, DateTime.utc_now()])
    advance!(60_000)
  end

  defp advance!(ms), do: row(@advance, [ms, digest() | actor()])

  defp state(window), do: one("SELECT state FROM relay.digest_windows WHERE id = $1", [window])

  defp due, do: List.flatten(rows(@due))

  defp audited(action) do
    now = DateTime.utc_now()
    params = [DateTime.add(now, -3600), DateTime.add(now, 3600), action, digest() | actor()]
    for [^action, target] <- rows(@audit, params), do: target
  end

  defp template_version! do
    ["created", _category, 1] =
      row(@category, [id(), "orders", "Orders", "transactional", digest() | actor()])

    definition = %{
      "default_locale" => "tr",
      "sensitivity" => "personal",
      "layout" => nil,
      "partials" => [],
      "producer_brand" => nil,
      "cells" => %{"sms" => %{"tr" => %{"body" => "Siparişiniz {{ order.id }}"}}}
    }

    create = [id(), id(), "order-shipped", nil, nil, "Order shipped", "orders", definition]
    ["created", _template, _draft, 1] = row(@create, create ++ [digest() | actor()])
    publish = ["order-shipped", nil, nil, nil, @variables, @measures, [], false, nil, nil]
    ["published", version_id, 1, _] = row(@publish, publish ++ [digest() | actor()])
    version_id
  end

  defp rendered!(notification, content, version_id, key) do
    delivery = delivery!(notification)
    assert one(@pin, [delivery, version_id, nil, [], "tr", false]) == "pinned"
    measures = %{"characters" => 10, "segments" => 1, "encoding" => "GSM7_TR"}
    assert one(@record, [delivery, content, measures, "sealed", key]) == "recorded"
    delivery
  end

  describe "WF-27 INV-3 accumulate first, then plan" do
    test "WF-27, INV-12: items join the one open window of their recipient and key, once each" do
      s = setup!()
      [a, b, c | _] = s.notifications

      assert ["opened", window, 1, 1, false, 1, first, first] = add(s, a)
      assert ["added", ^window, 1, 2, false, 2, ^first, _last] = add(s, b, actor: digest())
      assert ["exists", ^window, 1, 1, false, 2, ^first, _] = add(s, a)
      assert ["opened", other, 1, 1, false, 1, _, _] = add(s, c, key: digest())
      refute other == window

      assert error_message(
               "INSERT INTO relay.digest_windows (tenant_id) VALUES ('00000000-0000-7000-8000-000000000000')"
             ) =~ "permission denied"
    end

    test "WF-27: an unplanned open window is due for the sweep, a planned one when its time comes" do
      s = setup!()
      ["opened", window | _] = add(s, hd(s.notifications))
      assert window in due()

      at = DateTime.add(DateTime.utc_now(), 3_600, :second)
      assert ["schedule", fire_at, fire_at] = row(@plan, [window, at])
      refute window in due()

      assert ["kept", later, ^fire_at] = row(@plan, [window, DateTime.add(at, 60, :second)])
      assert DateTime.compare(later, fire_at) == :gt
      assert ["schedule", _, _] = row(@plan, [window, DateTime.add(at, -60, :second)])
    end

    test "WF-26: a window that is not due answers its firing time and keeps its items" do
      s = setup!()
      ["opened", window | _] = add(s, hd(s.notifications))
      at = DateTime.add(DateTime.utc_now(), 3_600, :second)
      ["schedule", fire_at, _] = row(@plan, [window, at])

      assert ["not_due", ^fire_at, 1, nil, nil] = row(@fire, [window])
      assert state(window) == "open"
    end

    test "INV-32: every window carries a deadline of at most 31 days" do
      s = setup!()
      ["opened", window | _] = add(s, hd(s.notifications))
      assert one(@deadline, [window]) == true
    end
  end

  describe "WF-29 cumulative digests" do
    test "WF-29: a later window of the same key carries the running total until the recipient reads it" do
      s = setup!()
      [a, b, c, d, e] = s.notifications
      ["opened", w1 | _] = add(s, a)
      add(s, b)
      due!(w1)

      assert ["fired", nil, 2, 2, 1] = row(@fire, [w1])
      assert ["not_open", nil, 2, 2, 1] = row(@fire, [w1])

      ["opened", w2, 2 | _] = add(s, c)
      due!(w2)
      assert ["fired", nil, 1, 3, 1] = row(@fire, [w2])

      assert Enum.sort(rows(@read, [s.recipient, c])) == Enum.sort([[w1, "read"], [w2, "read"]])

      ["opened", w3, 3 | _] = add(s, d)
      add(s, e)
      due!(w3)
      assert ["fired", nil, 2, 2, 3] = row(@fire, [w3])
    end

    test "WF-27: a read signal cancels the pending window of the notification's key" do
      s = setup!()
      [a, b | _] = s.notifications
      ["opened", window | _] = add(s, a)
      add(s, b)

      assert rows(@read, [s.recipient, b]) == [[window, "cancelled"]]
      assert state(window) == "cancelled"
      assert ["not_open" | _] = row(@fire, [window])
      assert rows(@read, [s.recipient, b]) == []
    end

    test "WF-27: a window whose only event went alone closes empty, never as a digest" do
      s = setup!()
      [first | _] = s.notifications
      assert ["opened", window, 1, 1, true, 0 | _] = add(s, first, leading: "immediate")
      due!(window)

      assert ["empty", nil, 0, nil, nil] = row(@fire, [window])
      assert state(window) == "empty"
    end
  end

  describe "WF-32 throttle counters" do
    test "WF-32: a key counts up to its limit, a repeat answers its first outcome and workflows share the key" do
      setup!()
      key = digest()
      [a, b, c] = for _ <- 1..3, do: digest()

      assert ["allowed", 1, false] = row(@hit, [key, a, 2, @hour])
      assert ["allowed", 2, false] = row(@hit, [key, b, 2, @hour])
      assert ["limited", 2, false] = row(@hit, [key, c, 2, @hour])
      assert ["allowed", 2, true] = row(@hit, [key, a, 2, @hour])
      assert ["allowed", 3, false] = row(@hit, [key, digest(), 5, @hour])

      assert ["reset", counter] = row(@reset, [key, digest() | actor()])
      assert ["allowed", 1, false] = row(@hit, [key, digest(), 2, @hour])
      assert ["not_active", nil] = row(@reset, [digest(), digest() | actor()])
      assert audited("throttle.reset") == [Ecto.UUID.cast!(counter)]
    end

    test "WF-37: a throttle window longer than 31 days is refused" do
      setup!()
      assert error_message(@hit, [digest(), digest(), 2, 2_678_400_001]) =~ "invalid_argument"
    end

    test "WF-32: a counter opens a new window when the active one ends" do
      setup!()
      key = digest()

      assert ["allowed", 1, false] = row(@hit, [key, digest(), 1, 1_000])
      assert ["limited", 1, false] = row(@hit, [key, digest(), 1, 1_000])
      advance!(2_000)
      assert ["allowed", 1, false] = row(@hit, [key, digest(), 1, 1_000])
    end
  end

  describe "WF-35 content repeats" do
    test "WF-35: the later of two identical renders to the same recipient and channel is skipped with its rule" do
      s = setup!()
      [a, b, c | _] = s.notifications
      version_id = template_version!()
      wrap = one(@wrap, [s.recipient])
      class = "notification_content"
      ["created", key] = row(@subject_key, [id(), s.recipient, class, digest(), wrap])
      content = digest()

      first = rendered!(a, content, version_id, key)
      second = rendered!(b, content, version_id, key)
      other = rendered!(c, digest(), version_id, key)

      results = Enum.sort([row(@check, [first, 300_000]), row(@check, [second, 300_000])])
      assert [["duplicate", repeated], ["unique", nil]] = results
      assert repeated in [first, second]
      assert row(@check, [other, 300_000]) == ["unique", nil]

      assert rows(@skipped, [[first, second]]) == [
               ["duplicate_content", "content_dedup.same_content"]
             ]

      again = Enum.sort([row(@check, [first, 300_000]), row(@check, [second, 300_000])])
      assert again == [["closed", nil], ["unique", nil]]
    end
  end
end
