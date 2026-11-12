defmodule Relay.Repo.Migrations.AddCorrelationDigests do
  use Ecto.Migration

  # AG-65
  # AG-11
  # AG-14
  # OP-57
  def up do
    for table <- ~w(waitpoints mailbox_records waitpoint_unmatched_events) do
      execute("ALTER TABLE relay.#{table} ADD COLUMN correlation_digest relay.sha256")
    end

    execute("ALTER TABLE relay.waitpoints ALTER COLUMN correlation_key DROP NOT NULL")
    execute("ALTER TABLE relay.waitpoint_unmatched_events ALTER COLUMN correlation_key DROP NOT NULL")

    execute("""
    ALTER TABLE relay.waitpoints ADD CONSTRAINT waitpoints_correlation_digest_check
      CHECK ((correlation_key IS NULL) <> (correlation_digest IS NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.waitpoint_unmatched_events ADD CONSTRAINT waitpoint_unmatched_events_correlation_digest_check
      CHECK ((correlation_key IS NULL) <> (correlation_digest IS NULL)) NOT VALID
    """)

    execute("""
    ALTER TABLE relay.mailbox_records ADD CONSTRAINT mailbox_records_correlation_digest_check
      CHECK ((kind = 'early_event')
        = ((correlation_key IS NOT NULL) <> (correlation_digest IS NOT NULL))) NOT VALID
    """)

    execute("ALTER TABLE relay.mailbox_records DROP CONSTRAINT mailbox_records_correlation_check")
    execute(guard())
  end

  def down, do: :ok

  defp guard do
    ~S"""
    CREATE OR REPLACE FUNCTION relay_private.waitpoints_guard() RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog, pg_temp
      SET TimeZone = 'UTC'
    AS $fn$
    DECLARE
      v_digest_fill boolean := OLD.correlation_digest IS NULL AND OLD.correlation_key IS NOT NULL
        AND NEW.correlation_key IS NULL AND NEW.correlation_digest IS NOT NULL;
    BEGIN
      IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION 'invariant_violation' USING HINT = 'AG-11';
      END IF;
      IF NEW.kind IS DISTINCT FROM OLD.kind OR NEW.waiter_kind IS DISTINCT FROM OLD.waiter_kind
        OR NEW.waiter_ref IS DISTINCT FROM OLD.waiter_ref
        OR NEW.waiter_mailbox_id IS DISTINCT FROM OLD.waiter_mailbox_id
        OR NEW.match_event_type IS DISTINCT FROM OLD.match_event_type
        OR ((NEW.correlation_key IS DISTINCT FROM OLD.correlation_key
          OR NEW.correlation_digest IS DISTINCT FROM OLD.correlation_digest) AND NOT v_digest_fill)
        OR NEW.subject_digest IS DISTINCT FROM OLD.subject_digest
        OR NEW.response_schema IS DISTINCT FROM OLD.response_schema
        OR NEW.opened_at IS DISTINCT FROM OLD.opened_at
        OR NEW.expires_at IS DISTINCT FROM OLD.expires_at
        OR NEW.heartbeat_interval_ms IS DISTINCT FROM OLD.heartbeat_interval_ms
        OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = 'a waitpoint keeps its identity, match and deadline', HINT = 'AG-11';
      END IF;
      IF OLD.state IN ('resolved', 'expired', 'cancelled') THEN
        IF (to_jsonb(NEW) - ARRAY['content_ct', 'claim_text_ct', 'default_response_ct',
            'field_key_id', 'fields_erased_at', 'updated_at', 'waiter_recipient_id',
            'waiter_recipient_kind', 'waiter_api_client_id', 'correlation_key',
            'correlation_digest'])
          IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['content_ct', 'claim_text_ct',
            'default_response_ct', 'field_key_id', 'fields_erased_at', 'updated_at',
            'waiter_recipient_id', 'waiter_recipient_kind', 'waiter_api_client_id',
            'correlation_key', 'correlation_digest'])
          OR (NEW.content_ct IS NOT NULL AND NEW.content_ct IS DISTINCT FROM OLD.content_ct)
          OR (NEW.claim_text_ct IS NOT NULL AND NEW.claim_text_ct IS DISTINCT FROM OLD.claim_text_ct)
          OR (NEW.default_response_ct IS NOT NULL
            AND NEW.default_response_ct IS DISTINCT FROM OLD.default_response_ct)
          OR (NEW.field_key_id IS NOT NULL AND NEW.field_key_id IS DISTINCT FROM OLD.field_key_id) THEN
          RAISE EXCEPTION 'invariant_violation'
            USING DETAIL = 'a closed waitpoint does not change', HINT = 'AG-11';
        END IF;
        RETURN NEW;
      END IF;
      IF NEW.state IS DISTINCT FROM OLD.state AND NOT (
        (OLD.state = 'open' AND NEW.state IN ('resolved', 'expired', 'cancelled', 'stalled'))
        OR (OLD.state = 'stalled' AND NEW.state IN ('open', 'resolved', 'expired', 'cancelled'))) THEN
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = 'waitpoint state transition not allowed', HINT = 'AG-10';
      END IF;
      IF NEW.state = 'resolved' AND NOT (NEW.resolved_at < OLD.expires_at) THEN
        RAISE EXCEPTION 'invariant_violation'
          USING DETAIL = 'an expired waitpoint cannot be resolved', HINT = 'AG-11';
      END IF;
      RETURN NEW;
    END
    $fn$
    """
  end
end
