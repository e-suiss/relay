defmodule Relay.Repo.Migrations.RecordWebhookDestinationEvents do
  use Ecto.Migration

  @ts "timestamp with time zone"
  @signature "relay_fn.webhook_destination_event_record(uuid, uuid, text, bigint, text, #{@ts}, text, bytea, uuid, bytea, #{@ts})"

  # WH-1
  # WH-8 (4)
  # WH-13
  # WF-11
  def up do
    execute(record())
    execute("REVOKE ALL ON FUNCTION #{@signature} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@signature} TO relay_app")
    execute("ALTER FUNCTION #{@signature} OWNER TO relay_owner")
  end

  def down, do: :ok

  defp record do
    ~S"""
    CREATE FUNCTION relay_fn.webhook_destination_event_record(p_event_id uuid, p_consumer_id uuid,
      p_event_type text, p_schema_version bigint, p_source text, p_occurred_at timestamptz,
      p_traceparent text, p_payload_ct bytea, p_payload_key_id uuid, p_payload_digest bytea,
      p_now timestamptz) RETURNS text
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_tenant uuid := relay_private.ctx_tenant_id();
      v_env relay.environment := relay_private.ctx_environment();
    BEGIN
      IF p_event_id IS NULL OR p_consumer_id IS NULL OR p_event_type IS NULL
        OR p_schema_version IS NULL OR p_occurred_at IS NULL OR p_payload_ct IS NULL
        OR p_payload_key_id IS NULL OR p_payload_digest IS NULL OR p_now IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'WH-13';
      END IF;
      INSERT INTO relay.webhook_events (tenant_id, environment, id, use_kind, consumer_id,
        event_type, schema_version, origin, source, occurred_at, traceparent, payload_ct,
        payload_key_id, payload_digest, created_at)
      VALUES (v_tenant, v_env, p_event_id, 'destination', p_consumer_id, p_event_type,
        p_schema_version, 'workflow', p_source, p_occurred_at, p_traceparent, p_payload_ct,
        p_payload_key_id, p_payload_digest, p_now)
      ON CONFLICT ON CONSTRAINT webhook_events_pkey DO NOTHING;
      IF FOUND THEN
        RETURN 'recorded';
      END IF;
      RETURN 'exists';
    END
    $fn$
    """
  end
end
