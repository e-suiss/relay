defmodule Relay.Agents.WaitpointInvariantsTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  defp scenario do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    stranger = member!(s, "subscriber")

    ["opened", id, _, nil] =
      open(s, waiter_ref: agent, responder_ids: [responder], expires_at: {:in, 3_600_000})

    %{
      s: s,
      agent: agent,
      responder: responder,
      stranger: stranger,
      id: id,
      value_key: content_key!(s, responder),
      stranger_key: content_key!(s, stranger),
      agent_key: content_key!(s, agent)
    }
  end

  defp as_owner(fun) do
    admin = connect(:admin)

    try do
      rolled_back(admin, fn ->
        ctx = scenario()
        rows("SET LOCAL ROLE relay_owner")
        fun.(ctx)
      end)
    after
      GenServer.stop(admin)
    end
  end

  defp insert_response(ctx, responder, key, opts \\ []) do
    sql_error(
      """
      INSERT INTO relay.waitpoint_responses (tenant_id, environment, id, waitpoint_id, waiter_kind,
        waiter_ref, responder_recipient_id, responder_actor_ref, session_actor_ref, via,
        evidence_level, subject_digest, value_ct, value_key_id, value_digest, responded_at,
        created_at)
      SELECT w.tenant_id, w.environment, $2, w.id, w.waiter_kind, w.waiter_ref, $3, 'acc_1', 'acc_1',
        'push', 'relay_session', COALESCE($5, w.subject_digest), 'v', $4, $6, $7, now()
      FROM relay.waitpoints w WHERE w.id = $1
      """,
      [
        ctx.id,
        id(),
        responder,
        key,
        opts[:subject_digest],
        digest(),
        opts[:responded_at] || DateTime.utc_now()
      ]
    )
  end

  defp ok_response(ctx, responder, key) do
    rows(
      """
      INSERT INTO relay.waitpoint_responses (tenant_id, environment, id, waitpoint_id, waiter_kind,
        waiter_ref, responder_recipient_id, responder_actor_ref, session_actor_ref, via,
        evidence_level, subject_digest, value_ct, value_key_id, value_digest, responded_at,
        created_at)
      SELECT w.tenant_id, w.environment, $2, w.id, w.waiter_kind, w.waiter_ref, $3, 'acc_1', 'acc_1',
        'push', 'relay_session', w.subject_digest, 'v', $4, $5, now(), now()
      FROM relay.waitpoints w WHERE w.id = $1
      """,
      [ctx.id, id(), responder, key, digest()]
    )
  end

  describe "AG-11 invariants in the database, bypassing the functions" do
    test "AG-11: the waiter cannot answer its own waitpoint" do
      as_owner(fn ctx ->
        error = insert_response(ctx, ctx.agent, ctx.agent_key)
        assert error.postgres.code in [:check_violation, :foreign_key_violation]

        assert sql_error(
                 """
                 INSERT INTO relay.waitpoint_responders (tenant_id, environment, waitpoint_id,
                   recipient_id, waiter_kind, waiter_ref, added_by, created_at)
                 SELECT tenant_id, environment, id, waiter_ref, waiter_kind, waiter_ref, 'escalation', now()
                 FROM relay.waitpoints WHERE id = $1
                 """,
                 [ctx.id]
               ).postgres.constraint == "waitpoint_responders_not_waiter_check"
      end)
    end

    test "AG-11: a recipient outside the responder set cannot answer" do
      as_owner(fn ctx ->
        error = insert_response(ctx, ctx.stranger, ctx.stranger_key)
        assert error.postgres.code == :foreign_key_violation
        assert error.postgres.constraint == "waitpoint_responses_responder_recipient_id_fkey"
      end)
    end

    test "AG-11: an answer after the deadline is refused" do
      as_owner(fn ctx ->
        late = DateTime.add(DateTime.utc_now(), 7_200, :second)
        error = insert_response(ctx, ctx.responder, ctx.value_key, responded_at: late)
        assert error.postgres.message == "invariant_violation"
        assert error.postgres.hint == "AG-11"

        assert sql_error(
                 """
                 UPDATE relay.waitpoints SET state = 'resolved', resolved_at = expires_at,
                   resolved_by_record_id = id WHERE id = $1
                 """,
                 [ctx.id]
               ).postgres.code in [:check_violation, :raise_exception]
      end)
    end

    test "AG-11: an answer to another subject is refused" do
      as_owner(fn ctx ->
        error = insert_response(ctx, ctx.responder, ctx.value_key, subject_digest: digest())
        assert error.postgres.constraint == "waitpoint_responses_subject_digest_fkey"
      end)
    end

    test "AG-11: a waitpoint takes one answer" do
      as_owner(fn ctx ->
        assert ok_response(ctx, ctx.responder, ctx.value_key) == []
        error = insert_response(ctx, ctx.responder, ctx.value_key)
        assert error.postgres.constraint == "waitpoint_responses_waitpoint_key"
      end)
    end

    test "AG-11: a resolved waitpoint does not change" do
      as_owner(fn ctx ->
        rows(
          """
          UPDATE relay.waitpoints SET state = 'cancelled', cancelled_at = now(),
            cancel_reason = 'done' WHERE id = $1
          """,
          [ctx.id]
        )

        for sql <- [
              "UPDATE relay.waitpoints SET state = 'open', cancelled_at = NULL, cancel_reason = NULL WHERE id = $1",
              "UPDATE relay.waitpoints SET tags = ARRAY['x'] WHERE id = $1",
              "UPDATE relay.waitpoints SET content_ct = 'other' WHERE id = $1"
            ] do
          assert sql_error(sql, [ctx.id]).postgres.message == "invariant_violation", sql
        end

        assert rows(
                 """
                 UPDATE relay.waitpoints SET content_ct = NULL, field_key_id = NULL,
                   fields_erased_at = now() WHERE id = $1
                 """,
                 [ctx.id]
               ) == []

        rows("SET LOCAL ROLE relay_migrator")

        assert sql_error("DELETE FROM relay.waitpoints WHERE id = $1", [ctx.id]).postgres.message ==
                 "invariant_violation"
      end)
    end

    test "AG-11: responses and their refusals are append-only" do
      as_owner(fn ctx ->
        ok_response(ctx, ctx.responder, ctx.value_key)
        rows("SET LOCAL ROLE relay_migrator")

        for table <- ["waitpoint_responses", "waitpoint_responders"] do
          assert sql_error("UPDATE relay.#{table} SET created_at = now()").postgres.message ==
                   "invariant_violation"

          assert sql_error("DELETE FROM relay.#{table}").postgres.message == "invariant_violation"
        end
      end)
    end
  end

  describe "AG-11 refusals through the function are recorded" do
    setup do
      scenario()
    end

    test "AG-11: each refusal reason is returned and recorded with its rule", ctx do
      digest = waitpoint(ctx.id, "subject_digest")
      base = [subject_digest: digest, value_key_id: ctx.value_key]

      assert ["rejected_is_waiter", nil] =
               respond(ctx.id, [responder_recipient_id: ctx.agent] ++ base)

      assert ["rejected_not_responder", nil] =
               respond(ctx.id, [responder_recipient_id: ctx.stranger] ++ base)

      assert ["rejected_session_mismatch", nil] =
               respond(
                 ctx.id,
                 [responder_recipient_id: ctx.responder, session_actor_ref: "acc_other"] ++ base
               )

      assert ["rejected_digest_mismatch", nil] =
               respond(ctx.id,
                 responder_recipient_id: ctx.responder,
                 subject_digest: digest(),
                 value_key_id: ctx.value_key
               )

      assert rows(
               "SELECT reason, rule_id FROM relay.waitpoint_response_rejections WHERE waitpoint_id = $1 ORDER BY created_at, id",
               [ctx.id]
             ) == [
               ["is_waiter", "waitpoint.response_is_waiter"],
               ["not_responder", "waitpoint.response_not_responder"],
               ["session_mismatch", "waitpoint.response_session_mismatch"],
               ["digest_mismatch", "waitpoint.response_digest_mismatch"]
             ]

      assert waitpoint(ctx.id, "state") == "open"

      assert mailbox_events(waitpoint(ctx.id, "waiter_mailbox_id")) ==
               ["waitpoint.created" | List.duplicate("waitpoint.response_rejected", 4)]
    end
  end
end
