defmodule Relay.Schema.FunctionSignaturesTest do
  use Relay.SqlCase, async: false

  import Relay.Golden

  alias Relay.Repo

  @schemas ~w(relay_fn relay_ops relay_private)

  @results %{
    "relay_fn.ctx_set" => ~w(active suspended closed),
    "relay_ops.tenant_create" => ~w(created exists conflict region_mismatch),
    "relay_fn.tenant_set_status" => ~w(changed unchanged invalid_transition version_conflict),
    "relay_fn.tenant_update_defaults" => ~w(updated unchanged version_conflict),
    "relay_fn.subtenant_upsert" => ~w(created updated unchanged archived),
    "relay_fn.subtenant_archive" => ~w(archived already_archived not_found),
    "relay_fn.setting_set" =>
      ~w(created updated unchanged cleared version_conflict subtenant_not_found),
    "relay_fn.idempotency_begin" => ~w(created replayed in_progress conflict),
    "relay_fn.idempotency_complete" => ~w(stored not_cacheable not_claimed),
    "relay_fn.recipient_create" => ~w(created exists tenant_inactive),
    "relay_fn.subject_key_create" => ~w(created exists recipient_not_found recipient_deleted),
    "relay_fn.subject_erase" => ~w(erased already_erased held not_found),
    "relay_fn.subject_key_retire" => ~w(retired already_destroyed held not_found),
    "relay_fn.tenant_key_register" => ~w(created exists active_exists),
    "relay_fn.tenant_key_destroy" => ~w(destroyed already_destroyed held not_allowed not_found),
    "relay_fn.blind_index_key_register" => ~w(created exists active_exists),
    "relay_fn.blind_index_key_rotate" => ~w(rotating not_active),
    "relay_fn.secret_ref_register" => ~w(created exists),
    "relay_fn.secret_ref_retire" => ~w(retired already_retired not_found),
    "relay_fn.legal_hold_place" => ~w(placed already_active recipient_not_found),
    "relay_fn.legal_hold_release" => ~w(released already_released not_found),
    "relay_fn.notification_accept" =>
      ~w(created duplicate recipient_not_found subtenant_not_found tenant_inactive),
    "relay_fn.delivery_open" =>
      ~w(opened exists notification_not_found notification_closed fallback_invalid tenant_inactive),
    "relay_fn.delivery_cancel" => ~w(cancelled already_terminal not_found),
    "relay_fn.notification_cancel" => ~w(cancelled already_closed not_found),
    "relay_fn.attempt_open" =>
      ~w(opened delivery_not_found delivery_not_sendable delivery_paused attempt_active tenant_inactive),
    "relay_fn.delivery_gate" => ~w(sendable cancelled paused expired terminal deferred not_found),
    "relay_fn.delivery_pause" => ~w(paused already_paused already_terminal not_found),
    "relay_fn.delivery_resume" => ~w(resumed not_paused already_terminal not_found),
    "relay_fn.delivery_hold" => ~w(held already_terminal not_found),
    "relay_fn.delivery_expire" => ~w(expired already_terminal not_found),
    "relay_fn.dead_letter_record" =>
      ~w(recorded already_open delivery_not_found delivery_terminal),
    "relay_fn.dead_letter_replay" =>
      ~w(replay_opened not_replayable approval_required cause_fix_required depth_exceeded expired not_open not_found tenant_inactive),
    "relay_fn.dead_letter_close" => ~w(closed not_open not_found),
    "relay_fn.dead_letter_replay_finish" => ~w(replayed not_replaying not_found),
    "relay_fn.attempt_start" => ~w(started not_pending not_found),
    "relay_fn.attempt_finish" => ~w(applied duplicate_ignored already_terminal not_found),
    "relay_fn.ledger_append" =>
      ~w(applied duplicate_ignored stale_ignored conflict_flagged delivery_not_found attempt_not_found rejected_future_timestamp),
    "relay_fn.webhook_receipt_record" => ~w(recorded duplicate),
    "relay_fn.webhook_receipt_mark" => ~w(marked already_final not_found),
    "relay_fn.outbox_append" => ~w(appended),
    "relay_fn.outbox_mark_dispatched" => ~w(dispatched already_dispatched not_found),
    "relay_fn.usage_record_append" => ~w(recorded duplicate conflict day_open),
    "relay_fn.audit_append" => ~w(appended),
    "relay_fn.dataset_version_publish" =>
      ~w(published exists dataset_not_found scope_not_allowed),
    "relay_fn.dataset_activate" => ~w(activated already_active version_not_found operator_pinned),
    "relay_fn.rl_gcra" => ~w(allowed limited ceiling cost_exceeds_burst),
    "relay_fn.rl_window" => ~w(allowed limited),
    "relay_fn.cc_acquire" => ~w(granted renewed full),
    "relay_fn.cc_release" => ~w(released not_held),
    "relay_private.partition_create" => ~w(created exists lock_timeout policy_missing),
    "relay_private.parent_analyze" => ~w(analyzed),
    "relay_ops.partition_policy_set" => ~w(updated unchanged not_partitioned),
    "relay_ops.audit_leaves_append" => ~w(appended index_gap not_leader),
    "relay_ops.audit_checkpoint_record" => ~w(recorded stale duplicate not_leader),
    "relay_ops.audit_checkpoint_publication_record" => ~w(recorded),
    "relay_ops.singleton_acquire" => ~w(acquired renewed held_by_other),
    "relay_ops.singleton_save" => ~w(saved not_leader),
    "relay_fn.drr_enqueue" =>
      ~w(enqueued exists queued_cap_exceeded lane_not_fair tenant_inactive),
    "relay_fn.drr_cancel" => ~w(cancelled none),
    "relay_ops.drr_take" => ~w(dispatched not_leader),
    "relay_ops.drr_weights_refresh" => ~w(refreshed not_leader),
    "relay_ops.load_shed_record" => ~w(recorded not_leader unchanged)
  }

  defp functions do
    Repo.query!("SET LOCAL search_path = pg_catalog")

    rows(
      """
      SELECT n.nspname || '.' || p.proname,
        pg_get_function_identity_arguments(p.oid),
        pg_get_function_result(p.oid),
        CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END,
        CASE p.provolatile WHEN 'i' THEN 'immutable' WHEN 's' THEN 'stable' ELSE 'volatile' END,
        pg_get_userbyid(p.proowner),
        COALESCE(array_to_string(p.proconfig, '; '), ''),
        CASE WHEN p.proacl IS NULL THEN 'PUBLIC' ELSE COALESCE((
          SELECT string_agg(g.name, ',' ORDER BY g.name COLLATE "C")
          FROM (SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END AS name
            FROM aclexplode(p.proacl) a
            WHERE a.privilege_type = 'EXECUTE' AND a.grantee <> p.proowner) g), '') END,
        p.prosrc
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = ANY ($1) AND p.prokind = 'f' AND p.prorettype <> 'trigger'::regtype
      """,
      [@schemas]
    )
  end

  test "OP-8: function signatures, results, security, owner, settings and EXECUTE match the golden file" do
    lines =
      for [name, args, result, security, volatility, owner, config, execute, _src] <- functions() do
        base =
          "#{name}(#{args}) -> #{result} | #{security} #{volatility} | owner #{owner} | #{config} | execute #{execute}"

        case @results[name] do
          nil -> base
          codes -> base <> " | results " <> Enum.join(codes, ",")
        end
      end
      |> Enum.sort_by(&hd(String.split(&1, " -> ", parts: 2)))

    assert_golden("db_functions.txt", Enum.map(lines, &[&1, "\n"]))
  end

  test "OP-8: every SECURITY DEFINER function fixes search_path and TimeZone and none is executable by PUBLIC" do
    for [name, _args, _result, security, _vol, owner, config, execute, _src] <- functions() do
      refute "PUBLIC" in String.split(execute, ","), "#{name} is executable by PUBLIC"

      if security == "definer" do
        assert String.contains?(config, "search_path=pg_catalog, pg_temp"), name
        assert String.contains?(config, "TimeZone=UTC"), name

        assert owner == expected_owner(name), "#{name} is owned by #{owner}"
      end
    end
  end

  test "OP-8: every declared result code appears in the function sources" do
    sources = Enum.map_join(functions(), "\n", &List.last/1)

    for {name, codes} <- @results, code <- codes do
      assert String.contains?(sources, "'#{code}'"), "#{name} never returns #{code}"
    end
  end

  test "OP-8: only relay_ops functions run as a role that bypasses row level security" do
    bypassing =
      rows("""
      SELECT n.nspname || '.' || p.proname
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_roles r ON r.oid = p.proowner
      WHERE p.prosecdef AND (r.rolbypassrls OR r.rolsuper)
        AND n.nspname IN ('relay', 'relay_fn', 'relay_private', 'relay_queue')
      """)

    assert bypassing == []
  end

  test "OP-8: the application role has no direct write privilege on the relay tables" do
    for {table, column} <- [
          {"tenants", "id"},
          {"notifications", "tenant_id"},
          {"deliveries", "tenant_id"},
          {"delivery_events", "tenant_id"},
          {"idempotency_keys", "tenant_id"},
          {"outbox_events", "tenant_id"},
          {"audit_log", "tenant_id"}
        ] do
      assert error_message(
               "INSERT INTO relay.#{table} (#{column}) VALUES ('00000000-0000-7000-8000-000000000000')"
             ) =~ "permission denied"
    end

    assert error_message("UPDATE relay.tenants SET version = version + 1") =~ "permission denied"
  end

  defp expected_owner("relay_fn." <> _), do: "relay_owner"
  defp expected_owner("relay_ops." <> _), do: "relay_maint"
  defp expected_owner("relay_private." <> _), do: "relay_migrator"
end
