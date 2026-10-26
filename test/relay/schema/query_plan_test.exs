defmodule Relay.Schema.QueryPlanTest do
  use Relay.SqlCase, async: false

  @scopes 40
  @recipients 125
  @active_recipients 8
  @per_recipient 32

  @plans [
    {"accept recipient check",
     """
     SELECT 1 FROM relay.recipients r
     WHERE r.tenant_id = $1 AND r.environment = $2 AND r.id = $3 AND r.state = 'active'
     """, ["uuid", "relay.environment", "uuid"], [{"recipients", ["recipients_pkey"]}]},
    {"accept duplicate",
     """
     UPDATE relay.notifications n SET duplicate_count = n.duplicate_count + 1,
         last_duplicate_at = now(), updated_at = now()
     WHERE n.tenant_id = $1 AND n.environment = $2 AND n.dedup_key = $3 AND n.recipient_id = $4
     RETURNING n.id
     """, ["uuid", "relay.environment", "text", "uuid"],
     [{"notifications", ["notifications_dedup_key_key"]}]},
    {"accept delivery notification",
     """
     SELECT * FROM relay.notifications n
     WHERE n.tenant_id = $1 AND n.environment = $2 AND n.id = $3
     FOR SHARE
     """, ["uuid", "relay.environment", "uuid"],
     [{"notifications", ["notifications_pkey", "notifications_id_recipient_id_key"]}]},
    {"accept delivery target",
     """
     SELECT d.id FROM relay.deliveries d
     WHERE d.tenant_id = $1 AND d.environment = $2
       AND d.notification_id = $3 AND d.channel = $4 AND d.target_key = $5
     """, ["uuid", "relay.environment", "uuid", "relay.channel", "bytea"],
     [{"deliveries", ["deliveries_target_key", "deliveries_notification_id_index"]}]},
    {"idempotency claim",
     """
     SELECT k.* FROM relay.idempotency_keys k
     WHERE k.tenant_id = $1 AND k.environment = $2 AND k.endpoint = $3 AND k.key = $4
       AND k.created_at > now() - interval '24 hours'
     ORDER BY k.created_at DESC LIMIT 1
     """, ["uuid", "relay.environment", "text", "relay.idempotency_key"],
     [{"idempotency_keys", ["idempotency_keys_lookup_index", "idempotency_keys_key_key"]}]},
    {"outbox claim",
     """
     SELECT o.id, o.created_at, o.event_type::text, o.stream_key, o.epoch, o.seq, o.payload,
       o.traceparent
     FROM relay.outbox_events o
     WHERE o.tenant_id = $1 AND o.environment = $2 AND o.state = 'pending'
     ORDER BY o.created_at, o.id
     LIMIT $3
     FOR UPDATE SKIP LOCKED
     """, ["uuid", "relay.environment", "integer"],
     [{"outbox_events", ["outbox_events_pending_index"]}]},
    {"ledger delivery lock",
     """
     SELECT * FROM relay.deliveries d
     WHERE d.tenant_id = $1 AND d.environment = $2 AND d.id = $3
     FOR UPDATE
     """, ["uuid", "relay.environment", "uuid"], [{"deliveries", ["deliveries_pkey"]}]},
    {"ledger delivered evidence",
     """
     SELECT EXISTS (
       SELECT 1 FROM relay.delivery_events e
       WHERE e.tenant_id = $1 AND e.environment = $2 AND e.delivery_id = $3
         AND e.detail -> 'effect' ->> 'delivery_rank' = '2'
         AND e.attempt_no IS DISTINCT FROM $4)
     """, ["uuid", "relay.environment", "uuid", "bigint"],
     [{"delivery_events", ["delivery_events_delivery_id_index"]}]},
    {"ledger projection update",
     """
     UPDATE relay.deliveries d SET delivery_rank = $4, projection_version = $5, updated_at = now()
     WHERE d.tenant_id = $1 AND d.environment = $2 AND d.id = $3 AND d.delivery_rank <= $4
     """, ["uuid", "relay.environment", "uuid", "smallint", "bigint"],
     [{"deliveries", ["deliveries_pkey"]}]}
  ]

  @seed [
    {"""
     CREATE TEMP TABLE plan_scopes ON COMMIT DROP AS
     SELECT uuidv7() AS tenant_id, (ARRAY['live', 'test'])[1 + g % 2]::relay.environment AS environment
     FROM generate_series(1, $1::int) g
     """, [@scopes]},
    {"""
     CREATE TEMP TABLE plan_slots ON COMMIT DROP AS
     SELECT p.relname::text AS table_name,
       (regexp_match(pg_get_expr(c.relpartbound, c.oid), '''([^'']+)'''))[1]::timestamptz
         + interval '1 hour' AS at,
       row_number() OVER (PARTITION BY p.relname ORDER BY c.relname) - 1 AS slot,
       count(*) OVER (PARTITION BY p.relname) AS slots
     FROM pg_inherits i
     JOIN pg_class c ON c.oid = i.inhrelid
     JOIN pg_class p ON p.oid = i.inhparent
     JOIN pg_namespace n ON n.oid = p.relnamespace
     WHERE n.nspname = 'relay' AND p.relkind = 'p'
       AND p.relname IN ('delivery_events', 'idempotency_keys', 'outbox_events')
     """, []},
    {"""
     INSERT INTO relay.recipients (tenant_id, environment, id, kind, external_id_ct,
       external_id_key_id, state, created_at, updated_at)
     SELECT s.tenant_id, s.environment, uuidv7(), 'subscriber', '\\x00', uuidv7(), 'active', now(),
       now()
     FROM plan_scopes s, generate_series(1, $1::int)
     """, [@recipients]},
    {"""
     INSERT INTO relay.notifications (tenant_id, environment, id, recipient_id, dedup_key,
       message_class, sender_type, is_test, state, duplicate_count, created_at, updated_at)
     SELECT r.tenant_id, r.environment, uuidv7(), r.id, 'plan:' || r.id || ':' || g,
       'transactional', 'system', false, 'active', 0, now(), now()
     FROM (SELECT x.tenant_id, x.environment, x.id,
             row_number() OVER (PARTITION BY x.tenant_id, x.environment ORDER BY x.id) AS no
           FROM relay.recipients x JOIN plan_scopes s USING (tenant_id, environment)) r,
       generate_series(1, $1::int) g
     WHERE r.no <= $2
     """, [@per_recipient, @active_recipients]},
    {"""
     INSERT INTO relay.deliveries (tenant_id, environment, id, notification_id, recipient_id,
       channel, target_kind, target_key, decision, delivery_rank, projection_version, created_at,
       updated_at)
     SELECT n.tenant_id, n.environment, uuidv7(), n.id, n.recipient_id, c, 'address',
       sha256(convert_to(n.id::text || c, 'UTF8')), 'send', 0, 1, now(), now()
     FROM relay.notifications n JOIN plan_scopes s USING (tenant_id, environment),
       unnest(ARRAY['email', 'sms']::relay.channel[]) c
     """, []},
    {"""
     INSERT INTO relay.delivery_events (tenant_id, environment, id, received_at, delivery_id,
       actor, event_type, occurred_at, projection_result, detail)
     SELECT d.tenant_id, d.environment, uuidv7(), b.at, d.id, 'relay', 'delivery.queued', b.at,
       'applied', '{"effect": {}}'
     FROM relay.deliveries d JOIN plan_scopes s USING (tenant_id, environment)
     JOIN plan_slots b ON b.table_name = 'delivery_events'
       AND b.slot = abs(hashtext(d.id::text)) % b.slots
     """, []},
    {"""
     INSERT INTO relay.idempotency_keys (tenant_id, environment, id, created_at, endpoint, key,
       request_fingerprint, expires_at, response_status, response_headers, response_body_ct,
       response_body_key_id)
     SELECT n.tenant_id, n.environment, uuidv7(), b.at, 'notifications.create', 'plan:' || n.id,
       sha256(convert_to(n.id::text, 'UTF8')), b.at + interval '24 hours', 201, '{}', '\\x00',
       uuidv7()
     FROM relay.notifications n JOIN plan_scopes s USING (tenant_id, environment)
     JOIN plan_slots b ON b.table_name = 'idempotency_keys'
       AND b.slot = abs(hashtext(n.id::text)) % b.slots
     """, []},
    {"""
     INSERT INTO relay.outbox_events (tenant_id, environment, id, created_at, event_type,
       stream_key, epoch, seq, payload, state, dispatched_at)
     SELECT d.tenant_id, d.environment, uuidv7(), b.at, 'delivery.queued', 'delivery:' || d.id, 1,
       1, '{}', CASE WHEN d.g = 1 THEN 'pending' ELSE 'dispatched' END,
       CASE WHEN d.g = 1 THEN NULL ELSE b.at END
     FROM (SELECT x.tenant_id, x.environment, x.id,
             row_number() OVER (PARTITION BY x.tenant_id, x.environment ORDER BY x.id) % 20 AS g
           FROM relay.deliveries x JOIN plan_scopes s USING (tenant_id, environment)) d
     JOIN plan_slots b ON b.table_name = 'outbox_events'
       AND b.slot = abs(hashtext(d.id::text)) % b.slots
     """, []}
  ]

  @analyzed ~w(recipients notifications deliveries delivery_events idempotency_keys outbox_events)

  defp seed do
    rows("SET LOCAL session_replication_role = replica")
    for {sql, params} <- @seed, do: rows(sql, params)
    rows("SET LOCAL session_replication_role = origin")
    for table <- @analyzed, do: rows("ANALYZE relay.#{table}")
  end

  defp parents do
    for [child, parent] <-
          rows("""
          SELECT c.relname::text, p.relname::text FROM pg_inherits i
          JOIN pg_class c ON c.oid = i.inhrelid
          JOIN pg_class p ON p.oid = i.inhparent
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'relay'
          """),
        into: %{},
        do: {child, parent}
  end

  defp nodes(%{"Node Type" => type} = node, parents) do
    here = {type, base(node["Relation Name"], parents), base(node["Index Name"], parents)}
    [here | Enum.flat_map(Map.get(node, "Plans", []), &nodes(&1, parents))]
  end

  defp base(nil, _parents), do: nil
  defp base(name, parents), do: Map.get(parents, name, name)

  defp generic_plan(sql, types) do
    rows("SET LOCAL plan_cache_mode = force_generic_plan")
    rows("PREPARE relay_plan (#{Enum.join(types, ", ")}) AS #{sql}")

    args =
      Enum.map_join(types, ", ", fn
        "uuid" -> "'00000000-0000-7000-8000-000000000000'"
        "relay.environment" -> "'live'"
        "relay.channel" -> "'email'"
        "bytea" -> "'\\x00'"
        "integer" -> "10"
        "smallint" -> "1"
        "bigint" -> "1"
        _text -> "'plan-test-key'"
      end)

    [[[%{"Plan" => plan}]]] = rows("EXPLAIN (FORMAT JSON) EXECUTE relay_plan (#{args})")
    rows("DEALLOCATE relay_plan")
    plan
  end

  defp pinned?(nodes, expected) do
    kinds = Enum.map(nodes, &elem(&1, 0))
    allowed = Map.new(expected)

    used =
      for {type, relation, index} <- nodes,
          type in ["Index Scan", "Index Only Scan"],
          do: {relation, index}

    Enum.all?(["Seq Scan", "Sort", "Bitmap Heap Scan"], &(&1 not in kinds)) and
      MapSet.new(used, &elem(&1, 0)) == MapSet.new(Map.keys(allowed)) and
      Enum.all?(used, fn {relation, index} -> index in Map.fetch!(allowed, relation) end)
  end

  test "OP-71 (3), OP-72 (4): the accept path, outbox claim, idempotency claim and ledger append use their pinned indexes with generic plans over seeded data" do
    admin = connect(:admin)

    rolled_back(admin, fn ->
      seed()
      parents = parents()

      off_plan =
        for {name, sql, types, expected} <- @plans,
            nodes = nodes(generic_plan(sql, types), parents),
            not pinned?(nodes, expected),
            do: {name, nodes}

      assert off_plan == []
    end)

    GenServer.stop(admin)
  end

  test "OP-72 (4): notifications carry the tenant, environment and recipient dependency statistics" do
    assert rows("""
           SELECT s.stxkind::text[],
             ARRAY(SELECT a.attname::text FROM unnest(s.stxkeys) k
               JOIN pg_attribute a ON a.attrelid = s.stxrelid AND a.attnum = k ORDER BY a.attnum)
           FROM pg_statistic_ext s JOIN pg_namespace n ON n.oid = s.stxnamespace
           WHERE n.nspname = 'relay' AND s.stxname = 'notifications_recipient_dependencies'
             AND s.stxrelid = 'relay.notifications'::regclass
           """) == [[["f"], ["tenant_id", "environment", "recipient_id"]]]
  end

  test "OP-11: every pinned index exists and is valid" do
    for {_name, _sql, _types, expected} <- @plans,
        {relation, indexes} <- expected,
        index <- indexes do
      assert [[^relation]] =
               rows(
                 "SELECT t.relname::text FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid WHERE i.relname = $1 AND x.indisvalid",
                 [index]
               )
    end
  end
end
