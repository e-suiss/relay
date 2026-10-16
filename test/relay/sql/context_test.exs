defmodule Relay.Sql.ContextTest do
  use Relay.SqlCase, async: true

  test "TN-13: a write function without tenant context raises scope_missing" do
    assert error_message("SELECT * FROM relay_fn.stream_next_seq('topic:a')") == "scope_missing"
  end

  test "TN-13: ctx_set returns the tenant status and an unknown tenant is not found" do
    tenant = tenant!()

    assert ctx(tenant, "live") == "active"
    assert ctx(tenant, "test") == "active"
    assert error_message("SELECT relay_fn.ctx_set($1, 'test')", [id()]) == "tenant_not_found"
    assert error_message("SELECT relay_fn.ctx_set($1, 'staging')", [tenant]) == "invalid_argument"
  end

  test "TN-13: the context is transaction-local" do
    tenant = tenant!()
    ctx(tenant)

    assert one("SELECT relay_private.ctx_tenant_id()") == tenant
    assert one("SELECT relay_private.ctx_environment()::text") == "test"
    assert one("SELECT current_setting('relay.tenant_id')") == Relay.Id.to_string(tenant)
  end

  test "TN-15: another tenant's rows are invisible inside a context" do
    %{notification: notification} = scenario!()
    other = tenant!()
    ctx(other)

    assert rows("SELECT id FROM relay.notifications WHERE id = $1", [notification]) == []

    assert row(
             "SELECT * FROM relay_fn.notification_cancel($1, 'rule', $2, $3, $4, $5, $6)",
             [notification, digest() | actor()]
           ) == ["not_found", 0]
  end

  test "TN-15: the other environment of the same tenant is invisible" do
    %{tenant: tenant, notification: notification} = scenario!()
    ctx(tenant, "live")

    assert rows("SELECT id FROM relay.notifications WHERE id = $1", [notification]) == []
  end

  test "API-72: a new row identifier must be a current UUIDv7" do
    tenant = tenant!()
    ctx(tenant)

    stale =
      Relay.Id.build(System.os_time(:millisecond) - 3_600_000, :crypto.strong_rand_bytes(10))

    for bad <- [stale, Ecto.UUID.bingenerate()] do
      assert error_message(
               "SELECT * FROM relay_fn.outbox_append($1, 'notification.created', 'topic:a', '{}', NULL)",
               [bad]
             ) == "invalid_argument"
    end
  end

  test "TN-4: setting_resolve prefers the subtenant, then the tenant, then tenant defaults" do
    tenant = tenant!()
    ctx(tenant)
    subtenant = id()

    ["created", ^subtenant, 1] =
      row("SELECT * FROM relay_fn.subtenant_upsert($1, 'org_1', 'Org', $2, $3, $4, $5, $6)", [
        subtenant,
        digest() | actor()
      ])

    set = fn subtenant_id, key, value ->
      row("SELECT * FROM relay_fn.setting_set($1, $2, $3, NULL, $4, $5, $6, $7, $8)", [
        subtenant_id,
        key,
        value,
        digest() | actor()
      ])
    end

    assert set.(nil, "quiet_hours.start", "22:00") == ["created", 1]
    assert set.(subtenant, "quiet_hours.start", "23:00") == ["created", 1]
    assert set.(nil, "quiet_hours.end", "07:00") == ["created", 1]

    resolved =
      rows("SELECT * FROM relay_fn.setting_resolve($1, $2)", [
        subtenant,
        ["quiet_hours.start", "quiet_hours.end", "default_locale", "missing"]
      ])

    assert resolved == [
             ["quiet_hours.start", "23:00", "subtenant"],
             ["quiet_hours.end", "07:00", "tenant"],
             ["default_locale", "tr", "tenant_defaults"],
             ["missing", nil, "none"]
           ]

    assert set.(nil, "quiet_hours.start", "21:00") == ["updated", 2]

    assert one("SELECT value FROM relay_fn.setting_resolve($1, ARRAY['quiet_hours.start'])", [
             subtenant
           ]) == "23:00"
  end
end
