defmodule Relay.Schema.QueryPlanTest do
  use Relay.SqlCase, async: false

  @plans [
    {"idempotency lookup",
     """
     SELECT k.* FROM relay.idempotency_keys k
     WHERE k.tenant_id = $1 AND k.environment = $2 AND k.endpoint = $3 AND k.key = $4
       AND k.created_at > now() - interval '24 hours'
     ORDER BY k.created_at DESC LIMIT 1
     """, ["uuid", "relay.environment", "text", "relay.idempotency_key"],
     [{"idempotency_keys", "idempotency_keys_lookup_index"}]},
    {"accept recipient check",
     """
     SELECT 1 FROM relay.recipients r
     WHERE r.tenant_id = $1 AND r.environment = $2 AND r.id = $3 AND r.state = 'active'
     """, ["uuid", "relay.environment", "uuid"], [{"recipients", "recipients_pkey"}]},
    {"accept duplicate",
     """
     UPDATE relay.notifications n SET duplicate_count = n.duplicate_count + 1,
         last_duplicate_at = now(), updated_at = now()
     WHERE n.tenant_id = $1 AND n.environment = $2 AND n.dedup_key = $3 AND n.recipient_id = $4
     RETURNING n.id
     """, ["uuid", "relay.environment", "text", "uuid"],
     [{"notifications", "notifications_dedup_key_key"}]},
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
     [{"outbox_events", "outbox_events_pending_index"}]}
  ]

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
    rows("SET LOCAL enable_seqscan = off")
    rows("SET LOCAL enable_bitmapscan = off")
    rows("PREPARE relay_plan (#{Enum.join(types, ", ")}) AS #{sql}")

    args =
      Enum.map_join(types, ", ", fn
        "uuid" -> "'00000000-0000-7000-8000-000000000000'"
        "relay.environment" -> "'live'"
        "integer" -> "10"
        _text -> "'plan-test-key'"
      end)

    [[[%{"Plan" => plan}]]] = rows("EXPLAIN (FORMAT JSON) EXECUTE relay_plan (#{args})")
    rows("DEALLOCATE relay_plan")
    plan
  end

  for {name, sql, types, scans} <- @plans do
    test "OP-11: the #{name} uses its pinned index with a generic plan and never scans a table" do
      admin = connect(:admin)

      rolled_back(admin, fn ->
        nodes = nodes(generic_plan(unquote(sql), unquote(types)), parents())
        types = Enum.map(nodes, &elem(&1, 0))

        scans = unquote(Macro.escape(scans))

        index_scans =
          for {type, relation, _index} <- nodes,
              type in ["Index Scan", "Index Only Scan", "Index Scan Backward"],
              into: MapSet.new(),
              do: relation

        refute "Seq Scan" in types, inspect(nodes)
        refute "Sort" in types, inspect(nodes)
        refute "Bitmap Heap Scan" in types, inspect(nodes)
        assert index_scans == MapSet.new(scans, &elem(&1, 0)), inspect(nodes)

        for {relation, index} <- scans do
          assert [[^relation]] =
                   rows(
                     "SELECT t.relname::text FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid WHERE i.relname = $1 AND x.indisvalid",
                     [index]
                   )
        end
      end)
    end
  end
end
