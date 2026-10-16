defmodule Relay.Sql.RetentionTest do
  use Relay.SqlCase, async: false

  alias Relay.Repo

  @retire "SELECT relay_fn.subject_key_retire($1, $2, $3, $4, $5, $6)"

  defp seed_periods(periods) do
    reset_role()
    installation = one("SELECT installation_tenant_id FROM relay.installation")
    version = id()

    Repo.query!(
      "INSERT INTO relay.datasets (name, json_schema, json_schema_digest, allowed_scopes, created_at) VALUES ('retention_periods', '{}', $1, ARRAY['installation'], now()) ON CONFLICT (name) DO NOTHING",
      [digest()]
    )

    Repo.query!(
      """
      INSERT INTO relay.dataset_versions (tenant_id, environment, id, dataset_name, version_no,
        content, content_digest, source, source_ref, valid_from, published_by_ref, created_at)
      SELECT $1, 'live', $2, 'retention_periods', COALESCE(max(v.version_no), 0) + 1, $3, $4,
        'operator', 'test', now(), 'test', now()
      FROM relay.dataset_versions v
      WHERE v.tenant_id = $1 AND v.environment = 'live' AND v.dataset_name = 'retention_periods'
      """,
      [installation, version, %{"periods" => periods}, digest()]
    )

    Repo.query!(
      """
      INSERT INTO relay.dataset_active (tenant_id, environment, dataset_name, version_id, activated_at, activated_by_ref)
      VALUES ($1, 'live', 'retention_periods', $2, now(), 'test')
      ON CONFLICT (tenant_id, environment, dataset_name)
        DO UPDATE SET version_id = EXCLUDED.version_id, activated_at = now()
      """,
      [installation, version]
    )
  end

  defp due(tenant) do
    as_role("relay_worker")

    rows(
      "SELECT subject_key_id, retention_class FROM relay_ops.retention_due(100000) WHERE tenant_id = $1",
      [tenant]
    )
  end

  test "OP-16: keys whose retention period ended are listed and retired with retention_end" do
    %{tenant: tenant, recipient: recipient} = scenario!()

    wrap =
      one("SELECT wrapping_key_id FROM relay.subject_keys WHERE recipient_id = $1", [recipient])

    ["created", key] =
      row("SELECT * FROM relay_fn.subject_key_create($1, $2, 'delivery_record', $3, $4)", [
        id(),
        recipient,
        digest(),
        wrap
      ])

    seed_periods([
      %{
        "region" => region(),
        "sector" => "general",
        "retention_class" => "delivery_record",
        "days" => 0
      },
      %{
        "region" => region(),
        "sector" => "general",
        "retention_class" => "recipient_profile",
        "days" => 3650
      }
    ])

    assert due(tenant) == [[key, "delivery_record"]]

    as_role("relay_api")
    ctx(tenant)
    assert one(@retire, [key, digest() | actor()]) == "retired"
    assert one(@retire, [key, digest() | actor()]) == "already_destroyed"
    assert one(@retire, [id(), digest() | actor()]) == "not_found"

    assert row(
             "SELECT state, destroy_reason, wrapped_dek IS NULL FROM relay.subject_keys WHERE id = $1",
             [key]
           ) ==
             ["destroyed", "retention_end", true]

    assert due(tenant) == []
  end

  test "OP-17: a legal hold keeps keys out of retention" do
    %{tenant: tenant, recipient: recipient} = scenario!()
    key = one("SELECT id FROM relay.subject_keys WHERE recipient_id = $1", [recipient])

    "placed" =
      one("SELECT relay_fn.legal_hold_place($1, 'recipient', $2, 'case', $3, $4, $5, $6, $7)", [
        id(),
        recipient,
        digest() | actor()
      ])

    seed_periods([
      %{
        "region" => region(),
        "sector" => "general",
        "retention_class" => "recipient_profile",
        "days" => 0
      }
    ])

    assert due(tenant) == []
    as_role("relay_api")
    ctx(tenant)
    assert one(@retire, [key, digest() | actor()]) == "held"
  end

  test "OP-26: receipt day keys are due seven days after their day" do
    tenant = tenant!()
    ctx(tenant)
    today = Date.utc_today()
    old = tenant_key!("receipt_day", Date.add(today, -10))
    _fresh = tenant_key!("receipt_day", Date.add(today, -2))
    as_role("relay_worker")

    assert rows(
             "SELECT key_id FROM relay_ops.receipt_keys_due($1, 100000) WHERE tenant_id = $2",
             [
               Date.add(today, -7),
               tenant
             ]
           ) == [[old]]

    assert one("SELECT relay_fn.tenant_key_destroy($1, 'receipt_day', $2, $3, $4, $5, $6)", [
             old,
             digest() | actor()
           ]) == "destroyed"
  end
end
