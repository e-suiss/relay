defmodule Relay.Repo.Migrations.CreateSubscriberTokenKeys do
  use Ecto.Migration

  @functions [
    {"relay_ops.subscriber_token_key_rotate(text, text, bigint, text, text)", "relay_maint",
     ~w(relay_app)},
    {"relay_ops.subscriber_token_key_retire(text, text)", "relay_maint", ~w(relay_app)}
  ]

  # IN-51
  # IN-42
  # TN-63
  # OP-9
  def up do
    Enum.each(statements(), &execute/1)

    for {signature, _owner, grantees} <- @functions do
      execute("REVOKE ALL ON FUNCTION #{signature} FROM PUBLIC")
      Enum.each(grantees, &execute("GRANT EXECUTE ON FUNCTION #{signature} TO #{&1}"))
    end
  end

  def down, do: :ok

  defp statements do
    [
      ~S"""
      CREATE TABLE relay.subscriber_token_keys (
        label text NOT NULL
          CONSTRAINT subscriber_token_keys_label_check
            CHECK (label ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
        state text NOT NULL
          CONSTRAINT subscriber_token_keys_state_check
            CHECK (state IN ('current', 'previous', 'retired')),
        activated_at timestamptz NOT NULL,
        activated_by text
          CONSTRAINT subscriber_token_keys_activated_by_check
            CHECK (char_length(activated_by) BETWEEN 1 AND 256),
        activation_reason text
          CONSTRAINT subscriber_token_keys_activation_reason_check
            CHECK (char_length(activation_reason) BETWEEN 1 AND 1024),
        superseded_at timestamptz,
        verify_until timestamptz,
        retired_at timestamptz,
        retired_reason text
          CONSTRAINT subscriber_token_keys_retired_reason_check
            CHECK (retired_reason IN ('window_closed', 'superseded', 'compromise')),
        retired_by text
          CONSTRAINT subscriber_token_keys_retired_by_check
            CHECK (char_length(retired_by) BETWEEN 1 AND 256),
        retirement_note text
          CONSTRAINT subscriber_token_keys_retirement_note_check
            CHECK (char_length(retirement_note) BETWEEN 1 AND 1024),
        created_at timestamptz NOT NULL,
        updated_at timestamptz NOT NULL,
        CONSTRAINT subscriber_token_keys_pkey PRIMARY KEY (label),
        CONSTRAINT subscriber_token_keys_superseded_check
          CHECK ((state = 'current') = (superseded_at IS NULL AND verify_until IS NULL)),
        CONSTRAINT subscriber_token_keys_retired_check
          CHECK ((state = 'retired') = (retired_at IS NOT NULL AND retired_reason IS NOT NULL))
      )
      """,
      """
      CREATE UNIQUE INDEX subscriber_token_keys_current_key ON relay.subscriber_token_keys
        ((state)) WHERE state = 'current'
      """,
      """
      CREATE UNIQUE INDEX subscriber_token_keys_previous_key ON relay.subscriber_token_keys
        ((state)) WHERE state = 'previous'
      """,
      "GRANT SELECT ON relay.subscriber_token_keys TO relay_owner, relay_app",
      "GRANT SELECT, INSERT, UPDATE ON relay.subscriber_token_keys TO relay_maint",
      ~S"""
      INSERT INTO relay.subscriber_token_keys (label, state, activated_at, created_at, updated_at)
      VALUES ('subscriber-token', 'current', now(), now(), now())
      """,
      rotate(),
      retire()
    ]
  end

  defp rotate do
    ~S"""
    CREATE FUNCTION relay_ops.subscriber_token_key_rotate(p_label text, p_default_label text,
      p_window_seconds bigint, p_actor text, p_reason text)
      RETURNS TABLE (result text, previous_label text, verify_until timestamptz)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_previous text;
      v_until timestamptz;
    BEGIN
      IF p_label IS NULL OR p_default_label IS NULL OR p_window_seconds IS NULL
        OR p_window_seconds < 1 OR p_actor IS NULL OR p_reason IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-51';
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('relay.subscriber_token_keys', 0));
      INSERT INTO relay.subscriber_token_keys AS k (label, state, activated_at, created_at,
        updated_at)
      SELECT p_default_label, 'current', now(), now(), now()
      WHERE NOT EXISTS (SELECT 1 FROM relay.subscriber_token_keys c WHERE c.state = 'current')
        AND NOT EXISTS (SELECT 1 FROM relay.subscriber_token_keys u WHERE u.label = p_default_label);
      IF EXISTS (SELECT 1 FROM relay.subscriber_token_keys u WHERE u.label = p_label) THEN
        RETURN QUERY SELECT 'label_used'::text, NULL::text, NULL::timestamptz;
        RETURN;
      END IF;
      UPDATE relay.subscriber_token_keys k SET state = 'retired', retired_at = now(),
          retired_reason = CASE WHEN k.verify_until <= now() THEN 'window_closed'
            ELSE 'superseded' END,
          retired_by = p_actor, updated_at = now()
        WHERE k.state = 'previous';
      v_until := now() + p_window_seconds * interval '1 second';
      UPDATE relay.subscriber_token_keys k SET state = 'previous', superseded_at = now(),
          verify_until = v_until, updated_at = now()
        WHERE k.state = 'current'
        RETURNING k.label INTO v_previous;
      INSERT INTO relay.subscriber_token_keys AS k (label, state, activated_at, activated_by,
        activation_reason, created_at, updated_at)
      VALUES (p_label, 'current', now(), p_actor, p_reason, now(), now());
      RETURN QUERY SELECT 'rotated'::text, v_previous,
        CASE WHEN v_previous IS NULL THEN NULL::timestamptz ELSE v_until END;
    END
    $fn$
    """
  end

  defp retire do
    ~S"""
    CREATE FUNCTION relay_ops.subscriber_token_key_retire(p_actor text, p_reason text)
      RETURNS TABLE (result text, label text)
    LANGUAGE plpgsql VOLATILE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
    #variable_conflict use_column
    DECLARE
      v_label text;
    BEGIN
      IF p_actor IS NULL OR p_reason IS NULL THEN
        RAISE EXCEPTION 'invalid_argument' USING HINT = 'IN-51';
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('relay.subscriber_token_keys', 0));
      UPDATE relay.subscriber_token_keys k SET state = 'retired', retired_at = now(),
          retired_reason = 'compromise', retired_by = p_actor, retirement_note = p_reason,
          updated_at = now()
        WHERE k.state = 'previous'
        RETURNING k.label INTO v_label;
      IF v_label IS NULL THEN
        RETURN QUERY SELECT 'no_previous'::text, NULL::text;
        RETURN;
      END IF;
      RETURN QUERY SELECT 'retired'::text, v_label;
    END
    $fn$
    """
  end
end
