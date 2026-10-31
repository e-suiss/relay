defmodule Relay.Sql.TenancyTest do
  use Relay.SqlCase, async: false

  @create "SELECT * FROM relay_ops.tenant_create($1, $2, $3, $4, $5, $6, NULL, NULL, $7, $8, $9, $10, $11)"

  defp create(id, access_id, region, timezone \\ "Europe/Istanbul") do
    row(@create, [id, access_id, region, "general", timezone, "tr", digest() | actor()])
  end

  defp set_status(status, reason, version \\ nil) do
    row("SELECT * FROM relay_fn.tenant_set_status($1, $2, $3, $4, $5, $6, $7, $8)", [
      status,
      reason,
      version,
      digest() | actor()
    ])
  end

  test "TN-6: tenant_create creates once and a replay of the mapping event returns exists" do
    tenant = id()
    access_id = "acc_" <> Base.encode16(tenant)

    assert create(tenant, access_id, region()) == ["created", tenant]
    assert create(id(), access_id, region()) == ["exists", tenant]
    assert create(id(), access_id, region(), "Europe/Berlin") == ["conflict", tenant]
  end

  test "INV-41: a tenant outside the installation region is rejected" do
    other = Enum.find(~w(tr eu us), &(&1 != region()))

    assert create(id(), "acc_x" <> Base.encode16(digest()), other) == ["region_mismatch", nil]
  end

  test "TN-46: tenant creation writes its audit record in the live environment" do
    tenant = tenant!()
    ctx(tenant, "live")

    now = DateTime.utc_now()

    assert rows(
             "SELECT action, target_id FROM relay_fn.audit_query($1, $2, 'tenant.created', NULL, 10, $3, $4, $5, $6, $7)",
             [DateTime.add(now, -3600), DateTime.add(now, 3600), digest() | actor()]
           ) == [["tenant.created", Relay.Id.to_string(tenant)]]
  end

  test "TN-10: status transitions are one way into closed and versioned" do
    tenant = tenant!()
    ctx(tenant, "live")

    assert set_status("suspended", "billing", 1) == ["changed", 2]
    assert set_status("suspended", "billing") == ["unchanged", 2]
    assert set_status("active", nil, 1) == ["version_conflict", 2]
    assert set_status("active", nil, 2) == ["changed", 3]
    assert set_status("closed", "offboarded") == ["changed", 4]
    assert set_status("active", nil) == ["invalid_transition", 4]

    assert error_message(
             "SELECT * FROM relay_fn.tenant_set_status('paused', 'x', NULL, $1, $2, $3, $4, $5)",
             [digest() | actor()]
           ) == "invalid_argument"
  end

  test "TN-10: a suspended tenant cannot open new work but the ledger keeps running" do
    %{tenant: tenant, recipient: recipient, notification: notification} = scenario!()
    delivery = delivery!(notification)
    ctx(tenant, "live")
    ["changed", 2] = set_status("suspended", "abuse")
    ctx(tenant, "test")

    assert ctx(tenant, "test") == "suspended"

    assert row(
             "SELECT result, notification_id FROM relay_fn.notification_accept($1, $2, NULL, 'd2', 'transactional', NULL, 'system', NULL, NULL, NULL, false, NULL)",
             [id(), recipient]
           ) == ["tenant_inactive", nil]

    assert row(
             "SELECT * FROM relay_fn.delivery_open($1, $2, 'email', 'address', NULL, $3, NULL, NULL, NULL, 'send', NULL, NULL, NULL, NULL)",
             [id(), notification, digest()]
           ) == ["tenant_inactive", nil]

    assert row("SELECT * FROM relay_fn.attempt_open($1, $2, NULL, NULL, NULL)", [id(), delivery]) ==
             ["tenant_inactive", nil]

    assert row(
             "SELECT * FROM relay_fn.recipient_create($1, 'subscriber', NULL, NULL, $2, $3, $4, $5)",
             [
               id(),
               digest(),
               id(),
               digest(),
               id()
             ]
           ) == ["tenant_inactive", nil]

    assert [result, 0, _] = ledger!(delivery, actor: "relay", event_type: "delivery.note")
    assert result == "stale_ignored"

    assert one("SELECT relay_fn.delivery_cancel($1, 'tenant_suspended', $2, $3, $4, $5, $6)", [
             delivery,
             digest() | actor()
           ]) == "cancelled"
  end

  test "TN-2: tenant defaults are updated with a version check and the region never changes" do
    tenant = tenant!()
    ctx(tenant, "live")
    sql = "SELECT * FROM relay_fn.tenant_update_defaults($1, $2, $3, $4, $5, $6, $7, $8, $9)"

    assert row(sql, ["Europe/Berlin", nil, nil, 1, digest() | actor()]) == ["updated", 2]
    assert row(sql, ["Europe/Berlin", nil, nil, nil, digest() | actor()]) == ["unchanged", 2]
    assert row(sql, [nil, "de", nil, 1, digest() | actor()]) == ["version_conflict", 2]

    assert row(
             "SELECT default_timezone, default_locale, region FROM relay.tenants WHERE id = $1",
             [
               tenant
             ]
           ) == ["Europe/Berlin", "tr", region()]
  end

  test "TN-46: tenant-level changes require the live environment context" do
    tenant = tenant!()
    ctx(tenant, "test")

    assert error_message(
             "SELECT * FROM relay_fn.tenant_set_status('suspended', 'x', NULL, $1, $2, $3, $4, $5)",
             [digest() | actor()]
           ) == "invalid_argument"
  end

  test "TN-3: subtenant upsert is idempotent per Access organization and archive is terminal" do
    tenant = tenant!()
    ctx(tenant)
    subtenant = id()
    upsert = "SELECT * FROM relay_fn.subtenant_upsert($1, $2, $3, $4, $5, $6, $7, $8)"

    assert row(upsert, [subtenant, "org_9", "Acme", digest() | actor()]) == [
             "created",
             subtenant,
             1
           ]

    assert row(upsert, [subtenant, "org_9", "Acme", digest() | actor()]) == [
             "unchanged",
             subtenant,
             1
           ]

    assert row(upsert, [subtenant, "org_9", "Acme Ltd", digest() | actor()]) == [
             "updated",
             subtenant,
             2
           ]

    archive = "SELECT relay_fn.subtenant_archive($1, $2, $3, $4, $5, $6)"
    assert one(archive, [subtenant, digest() | actor()]) == "archived"
    assert one(archive, [subtenant, digest() | actor()]) == "already_archived"
    assert one(archive, [id(), digest() | actor()]) == "not_found"

    assert row(upsert, [subtenant, "org_9", "Acme", digest() | actor()]) == [
             "archived",
             subtenant,
             3
           ]

    ctx(tenant, "live")

    assert row(upsert, [subtenant, "org_9", "Acme", digest() | actor()]) == [
             "created",
             subtenant,
             1
           ]
  end

  test "TN-4: setting_set reports created, cleared, version conflicts and unknown subtenants" do
    tenant = tenant!()
    ctx(tenant)
    sql = "SELECT * FROM relay_fn.setting_set($1, $2, $3, $4, $5, $6, $7, $8, $9)"

    assert row(sql, [nil, "channel.sms.enabled", true, nil, digest() | actor()]) == ["created", 1]

    assert row(sql, [nil, "channel.sms.enabled", true, nil, digest() | actor()]) == [
             "unchanged",
             1
           ]

    assert row(sql, [nil, "channel.sms.enabled", false, 5, digest() | actor()]) == [
             "version_conflict",
             1
           ]

    assert row(sql, [nil, "channel.sms.enabled", nil, 1, digest() | actor()]) == ["cleared", 2]

    assert row(sql, [id(), "channel.sms.enabled", true, nil, digest() | actor()]) == [
             "subtenant_not_found",
             nil
           ]

    assert error_message(sql, [nil, "Bad Key", true, nil, digest() | actor()]) ==
             "invalid_argument"
  end
end
