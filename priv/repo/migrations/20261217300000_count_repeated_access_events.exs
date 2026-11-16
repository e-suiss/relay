defmodule Relay.Repo.Migrations.CountRepeatedAccessEvents do
  use Ecto.Migration

  # WH-51
  # WH-49 (3)
  # E-94
  def up do
    execute("""
    ALTER TABLE relay.access_event_receipts
      ADD COLUMN duplicate_count bigint NOT NULL DEFAULT 0
    """)

    execute("ALTER TABLE relay.access_event_receipts ADD COLUMN last_duplicate_at timestamptz")
    execute(record())
    execute("DROP FUNCTION relay_ops.access_event_receipt_read(uuid)")
    execute(read())
    execute("REVOKE ALL ON FUNCTION relay_ops.access_event_receipt_read(uuid) FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION relay_ops.access_event_receipt_read(uuid) TO relay_worker")
  end

  def down, do: :ok

  defp record do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_ops.access_event_receipt_record(p_id uuid, p_webhook_id text,
      p_event_type text, p_access_tenant_id text, p_payload jsonb, p_body_digest bytea,
      p_traceparent text) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    BEGIN
      IF p_id IS NULL OR p_webhook_id IS NULL OR p_event_type IS NULL OR p_payload IS NULL
        OR p_body_digest IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'E-36';
      END IF;
      INSERT INTO relay.access_event_receipts (id, webhook_id, event_type, access_tenant_id,
        payload, body_digest, state, reason, traceparent, received_at, processed_at)
      VALUES (p_id, p_webhook_id, p_event_type, p_access_tenant_id, p_payload, p_body_digest,
        'received', NULL, p_traceparent, now(), NULL)
      ON CONFLICT (webhook_id) DO NOTHING;
      IF FOUND THEN
        RETURN 'recorded';
      END IF;
      UPDATE relay.access_event_receipts r
        SET duplicate_count = r.duplicate_count + 1, last_duplicate_at = now()
        WHERE r.webhook_id = p_webhook_id;
      RETURN 'duplicate';
    END
    $fn$
    """
  end

  defp read do
    ~S"""
    CREATE FUNCTION relay_ops.access_event_receipt_read(p_id uuid)
      RETURNS TABLE (webhook_id text, event_type text, access_tenant_id text, payload jsonb,
        state text, reason text, duplicate_count bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT r.webhook_id, r.event_type::text, r.access_tenant_id, r.payload, r.state, r.reason,
        r.duplicate_count
      FROM relay.access_event_receipts r
      WHERE r.id = p_id
    $fn$
    """
  end
end
