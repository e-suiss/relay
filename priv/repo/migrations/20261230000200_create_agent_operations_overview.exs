defmodule Relay.Repo.Migrations.CreateAgentOperationsOverview do
  use Ecto.Migration

  @overview "relay_ops.agent_operations_overview(timestamp with time zone, bigint)"

  # AG-54
  # AG-71
  # OP-8
  def up do
    execute(overview())
    execute("REVOKE ALL ON FUNCTION #{@overview} FROM PUBLIC")
    execute("GRANT EXECUTE ON FUNCTION #{@overview} TO relay_worker")
  end

  def down, do: :ok

  defp overview do
    ~S"""
    CREATE FUNCTION relay_ops.agent_operations_overview(p_now timestamptz, p_silent_s bigint)
      RETURNS TABLE (silent_waitpoints bigint, stalled_waitpoints bigint, responses_hour bigint,
        median_response_ms bigint, opened_day bigint, responded_day bigint, opened_week bigint,
        responded_week bigint, resolved_week bigint, escalated_week bigint,
        evidence_channel_claim bigint, evidence_relay_session bigint,
        evidence_access_aas_ref bigint, held_notifications bigint, open_ceiling_events bigint)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    SET TimeZone = 'UTC'
    AS $fn$
      SELECT
        (SELECT count(*) FROM relay.waitpoints w
          WHERE w.state IN ('open', 'stalled')
            AND w.state_changed_at <= p_now - make_interval(secs => p_silent_s)),
        (SELECT count(*) FROM relay.waitpoints w WHERE w.state = 'stalled'),
        (SELECT count(*) FROM relay.waitpoint_responses s
          WHERE s.responded_at > p_now - interval '1 hour' AND s.responded_at <= p_now),
        COALESCE((SELECT percentile_cont(0.5) WITHIN GROUP
            (ORDER BY extract(epoch FROM s.responded_at - w.opened_at) * 1000)
          FROM relay.waitpoint_responses s
          JOIN relay.waitpoints w ON w.tenant_id = s.tenant_id
            AND w.environment = s.environment AND w.id = s.waitpoint_id
          WHERE s.responded_at > p_now - interval '1 hour' AND s.responded_at <= p_now),
          0)::bigint,
        (SELECT count(*) FROM relay.waitpoints w
          WHERE w.kind IN ('question', 'review') AND w.opened_at > p_now - interval '1 day'
            AND w.opened_at <= p_now),
        (SELECT count(*) FROM relay.waitpoint_responses s
          WHERE s.responded_at > p_now - interval '1 day' AND s.responded_at <= p_now),
        (SELECT count(*) FROM relay.waitpoints w
          WHERE w.kind IN ('question', 'review') AND w.opened_at > p_now - interval '8 days'
            AND w.opened_at <= p_now - interval '1 day'),
        (SELECT count(*) FROM relay.waitpoint_responses s
          WHERE s.responded_at > p_now - interval '8 days'
            AND s.responded_at <= p_now - interval '1 day'),
        (SELECT count(*) FROM relay.waitpoints w
          WHERE w.state = 'resolved' AND w.resolved_at > p_now - interval '7 days'),
        (SELECT count(*) FROM relay.waitpoints w
          JOIN relay.waitpoint_responses s ON s.tenant_id = w.tenant_id
            AND s.environment = w.environment AND s.id = w.resolution_response_id
          JOIN relay.waitpoint_responders r ON r.tenant_id = s.tenant_id
            AND r.environment = s.environment AND r.waitpoint_id = s.waitpoint_id
            AND r.recipient_id = s.responder_recipient_id
          WHERE w.state = 'resolved' AND w.resolved_at > p_now - interval '7 days'
            AND r.added_by = 'escalation'),
        (SELECT count(*) FROM relay.waitpoint_responses s
          WHERE s.responded_at > p_now - interval '7 days'
            AND s.evidence_level = 'channel_claim'),
        (SELECT count(*) FROM relay.waitpoint_responses s
          WHERE s.responded_at > p_now - interval '7 days'
            AND s.evidence_level = 'relay_session'),
        (SELECT count(*) FROM relay.waitpoint_responses s
          WHERE s.responded_at > p_now - interval '7 days'
            AND s.evidence_level = 'access_aas_ref'),
        (SELECT count(*) FROM relay.agent_ceiling_holds h WHERE h.state = 'held'),
        (SELECT count(*) FROM relay.agent_ceiling_events e WHERE e.state = 'open')
    $fn$
    """
  end
end
