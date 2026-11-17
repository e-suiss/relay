defmodule Relay.Agents.ResponseCollectionTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  @describe "SELECT relay_fn.waitpoint_describe($1, 'guardian_approval', NULL, NULL, NULL)"
  @mint "SELECT * FROM relay_fn.waitpoint_response_token_mint($1, $2, $3, $4)"
  @consume "SELECT * FROM relay_fn.waitpoint_response_token_consume($1, 'sms', $2, $3, $4)"
  @process "SELECT * FROM relay_fn.waitpoint_response_token_process($1, $2)"
  @rejections "SELECT reason, rule_id::text FROM relay.waitpoint_response_rejections WHERE waitpoint_id = $1 ORDER BY created_at, id"
  @events "SELECT payload FROM relay.outbox_events WHERE event_type = $1 AND stream_key = $2 ORDER BY seq"
  @token "SELECT state, outcome, value_ct FROM relay.waitpoint_response_tokens WHERE id = $1"
  @ttl 900_000

  setup do
    scenario()
  end

  defp scenario do
    s = setup!()
    agent = member!(s, "agent")
    responder = member!(s, "subscriber")
    other = member!(s, "subscriber")

    %{
      s: s,
      agent: agent,
      responder: responder,
      other: other,
      value_key: content_key!(s, responder),
      other_key: content_key!(s, other)
    }
  end

  defp asking(ctx, opts \\ []) do
    defaults = [waiter_ref: ctx.agent, responder_ids: [ctx.responder, ctx.other]]
    ["opened", id, _, nil] = open(ctx.s, Keyword.merge(defaults, opts))
    id
  end

  defp guardian(ctx) do
    id = asking(ctx, kind: "review")
    "described" = one(@describe, [id])
    id
  end

  defp answer(ctx, id, opts \\ []) do
    defaults = [
      responder_recipient_id: ctx.responder,
      subject_digest: waitpoint(id, "subject_digest"),
      value_key_id: ctx.value_key
    ]

    respond(id, Keyword.merge(defaults, opts))
  end

  defp text(id), do: Relay.Id.to_string(id)
  defp events(id, type), do: List.flatten(rows(@events, [type, "waitpoint:" <> text(id)]))

  defp mint(ctx, id, opts \\ []) do
    token = id()
    recipient = Keyword.get(opts, :recipient, ctx.responder)
    [result, expires_at] = row(@mint, [token, id, recipient, Keyword.get(opts, :ttl, @ttl)])
    {result, token, expires_at}
  end

  defp consume(ctx, token, digest \\ digest()),
    do: row(@consume, [token, "sealed", ctx.value_key, digest])

  describe "AG-25 AG-26 E-86 the response record" do
    test "AG-25: the resolved event names the responder, the channel and the evidence level, never the value",
         ctx do
      id = asking(ctx)
      digest = digest()

      assert ["resolved", response] =
               answer(ctx, id, via: "in_app", value_ct: "sealed value", value_digest: digest)

      assert [data] = events(id, "waitpoint.resolved")
      assert data["response_id"] == text(response)
      assert data["responder"] == %{"recipient_id" => text(ctx.responder), "kind" => "subscriber"}
      assert data["channel"] == "in_app"
      assert data["evidence_level"] == "relay_session"
      assert data["response_digest"] == "sha256:" <> Base.encode16(digest, case: :lower)
      assert is_binary(data["responded_at"])
      assert is_binary(data["subject_digest"])
      refute Map.has_key?(data, "value")
      refute Map.has_key?(data, "access_decision_ref")
      refute Enum.any?(Map.keys(data), &String.contains?(&1, "approval"))
    end

    test "AG-25: the waiter's mailbox record carries the sealed value under the responder's key",
         ctx do
      id = asking(ctx)
      assert ["resolved", _response] = answer(ctx, id, value_ct: "sealed value")

      sql = """
      SELECT payload_ct, payload_subject_key_id, payload_tenant_key_id
      FROM relay.mailbox_records WHERE waitpoint_id = $1 AND event_type = 'waitpoint.resolved'
      """

      assert rows(sql, [id]) == [["sealed value", ctx.value_key, nil]]
    end

    test "AG-26: a channel outside the channel list is not named in the event", ctx do
      id = asking(ctx)
      assert ["resolved", _response] = answer(ctx, id, via: "link")
      assert [%{"channel" => nil}] = events(id, "waitpoint.resolved")
    end

    test "AG-27: a decision of the Access approval surface is recorded with its reference", ctx do
      id = asking(ctx)

      access = [via: "access", evidence_level: "access_aas_ref", evidence_ref: "aas-1"]
      assert ["resolved", _response] = answer(ctx, id, access)

      assert [data] = events(id, "waitpoint.resolved")
      assert data["evidence_level"] == "access_aas_ref"
      assert data["access_decision_ref"] == "aas-1"
      assert data["channel"] == nil
    end
  end

  describe "AG-28 AG-35 resolved once" do
    test "AG-28: a second response is rejected and the event carries the rule", ctx do
      id = asking(ctx)
      assert ["resolved", response] = answer(ctx, id)

      other = [responder_recipient_id: ctx.other, value_key_id: ctx.other_key]
      assert ["rejected_closed", nil] = answer(ctx, id, other)

      assert rows(@rejections, [id]) == [["closed", "waitpoint.response_closed"]]

      assert [%{"rule_id" => "waitpoint.response_closed"}] =
               events(id, "waitpoint.response_rejected")

      assert waitpoint(id, "resolution_response_id") == response
    end

    test "AG-35: the same response sent again changes nothing and is answered as the first",
         ctx do
      id = asking(ctx)
      digest = digest()
      assert ["resolved", response] = answer(ctx, id, value_digest: digest)
      assert ["duplicate", ^response] = answer(ctx, id, value_digest: digest)
      assert ["duplicate", ^response] = answer(ctx, id, value_digest: digest)
      assert rows(@rejections, [id]) == []
      assert events(id, "waitpoint.response_rejected") == []
      assert [_one] = events(id, "waitpoint.resolved")

      assert ["rejected_closed", nil] = answer(ctx, id, value_digest: digest())
    end

    test "INV-31: every refusal reports its rule", ctx do
      id = asking(ctx)
      stranger = member!(ctx.s, "subscriber")
      assert ["rejected_not_responder", nil] = answer(ctx, id, responder_recipient_id: stranger)
      assert ["rejected_digest_mismatch", nil] = answer(ctx, id, subject_digest: digest())

      assert Enum.map(events(id, "waitpoint.response_rejected"), & &1["rule_id"]) == [
               "waitpoint.response_not_responder",
               "waitpoint.response_digest_mismatch"
             ]

      assert waitpoint(id, "state") == "open"
    end
  end

  describe "AG-62 AG-32 guardian approval" do
    test "AG-62: only a decision of the Access approval surface closes a guardian approval",
         ctx do
      id = guardian(ctx)

      for via <- ["push", "in_app", "sms", "whatsapp"],
          level <- ["relay_session", "channel_claim"] do
        refused = answer(ctx, id, via: via, evidence_level: level)
        assert refused == ["rejected_evidence_level", nil]
      end

      assert waitpoint(id, "state") == "open"
      rule = ["evidence_level", "waitpoint.response_evidence_level"]
      assert rows(@rejections, [id]) == List.duplicate(rule, 8)

      access = [via: "access", evidence_level: "access_aas_ref", evidence_ref: "aas-9"]
      assert ["resolved", _response] = answer(ctx, id, access)

      assert waitpoint(id, "state") == "resolved"
    end

    test "AG-32: a guardian approval takes no response token", ctx do
      assert {"profile_refused", _token, nil} = mint(ctx, guardian(ctx))
    end
  end

  describe "AG-31 INV-33 response token" do
    test "AG-31: a token names one waitpoint and one responder and is used once", ctx do
      id = asking(ctx)
      assert {"minted", token, expires_at} = mint(ctx, id)
      assert DateTime.compare(expires_at, waitpoint(id, "expires_at")) == :lt
      digest = digest()

      assert ["consumed", ^id, responder] = consume(ctx, token, digest)
      assert responder == ctx.responder
      assert ["replayed", ^id, _responder] = consume(ctx, token, digest)
      assert ["already_consumed", ^id, _responder] = consume(ctx, token, digest())
      assert ["not_found", nil, nil] = consume(ctx, id())
    end

    test "AG-31: a resend rotates the earlier token", ctx do
      id = asking(ctx)
      assert {"minted", first, _expires_at} = mint(ctx, id)
      assert {"minted", kept, _expires_at} = mint(ctx, id, recipient: ctx.other)
      assert {"minted", second, _expires_at} = mint(ctx, id)

      assert ["rotated", ^id, _responder] = consume(ctx, first)
      assert ["consumed", ^id, _responder] = consume(ctx, second)

      assert ["consumed", ^id, other] = row(@consume, [kept, "sealed", ctx.other_key, digest()])
      assert other == ctx.other
    end

    test "AG-31: a token is short-lived and never outlives the deadline", ctx do
      id = asking(ctx, expires_at: {:in, 60_000})
      assert {"minted", token, expires_at} = mint(ctx, id)
      assert expires_at == waitpoint(id, "expires_at")

      long = asking(ctx)
      assert {"minted", short, _expires_at} = mint(ctx, long, ttl: 1_000)
      advance!(2_000)
      assert ["expired", ^long, _responder] = consume(ctx, short)

      advance!(60_000)
      assert ["expired", ^id, _responder] = consume(ctx, token)
      assert {"not_open", _token, nil} = mint(ctx, id)
    end

    test "AG-31: only a responder of an open question or review gets a token", ctx do
      id = asking(ctx)
      stranger = member!(ctx.s, "subscriber")
      assert {"not_responder", _token, nil} = mint(ctx, id, recipient: stranger)
      assert {"not_found", _token, nil} = mint(ctx, id())

      ["opened", event, _, nil] = open(ctx.s, kind: "event", waiter_ref: ctx.agent)
      assert {"not_found", _token, nil} = mint(ctx, event)

      assert ["resolved", _response] = answer(ctx, id)
      assert {"not_open", _token, nil} = mint(ctx, id)
    end

    test "AG-35: a consumed token is processed into a channel claim and settled", ctx do
      id = asking(ctx)
      assert {"minted", token, _expires_at} = mint(ctx, id)
      digest = digest()
      assert ["consumed", ^id, _responder] = consume(ctx, token, digest)
      assert row(@token, [token]) == ["processing", nil, "sealed"]

      assert ["settled", "resolved"] = row(@process, [token, id()])
      assert row(@token, [token]) == ["settled", "resolved", nil]
      assert ["already_settled", "resolved"] = row(@process, [token, id()])
      assert ["replayed", ^id, _responder] = consume(ctx, token, digest)

      assert [data] = events(id, "waitpoint.resolved")
      assert data["evidence_level"] == "channel_claim"
      assert data["channel"] == "sms"
      assert data["responder"]["recipient_id"] == text(ctx.responder)
    end

    test "AG-28: a token used after another response is settled as rejected, with the rule",
         ctx do
      id = asking(ctx)
      assert {"minted", token, _expires_at} = mint(ctx, id)
      other = [responder_recipient_id: ctx.other, value_key_id: ctx.other_key]
      assert ["resolved", _response] = answer(ctx, id, other)
      assert ["consumed", ^id, _responder] = consume(ctx, token)
      assert ["settled", "rejected_closed"] = row(@process, [token, id()])
      assert rows(@rejections, [id]) == [["closed", "waitpoint.response_closed"]]

      assert {"minted", unused, _expires_at} = mint(ctx, asking(ctx))
      assert ["not_processing", nil] = row(@process, [unused, id()])
      assert ["not_found", nil] = row(@process, [id(), id()])
    end

    test "INV-33: nothing the waiter reads names a token", ctx do
      id = asking(ctx)
      assert {"minted", token, _expires_at} = mint(ctx, id)
      assert ["consumed", ^id, _responder] = consume(ctx, token)
      assert ["settled", "resolved"] = row(@process, [token, id()])

      reads = [
        {"SELECT payload::text FROM relay.outbox_events WHERE stream_key = $1",
         ["waitpoint:" <> text(id)]},
        {"SELECT to_jsonb(r)::text FROM relay.mailbox_records r WHERE r.waitpoint_id = $1", [id]},
        {"SELECT to_jsonb(g)::text FROM relay_fn.waitpoint_get($1) g", [id]}
      ]

      for {sql, params} <- reads do
        read = List.flatten(rows(sql, params))
        assert read != []
        refute Enum.any?(read, &String.contains?(&1, "token"))
        refute Enum.any?(read, &String.contains?(&1, text(token)))
      end
    end
  end

  describe "AG-11 constraints behind the token functions" do
    defp minted do
      ctx = scenario()
      {"minted", token, _expires_at} = mint(ctx, asking(ctx))
      %{token: token}
    end

    test "AG-11: a token row keeps its states consistent and is never deleted" do
      as_owner(&minted/0, fn %{token: token} ->
        for {sql, constraint} <- [
              {"UPDATE relay.waitpoint_response_tokens SET state = 'settled' WHERE id = $1",
               "waitpoint_response_tokens_consumed_check"},
              {"UPDATE relay.waitpoint_response_tokens SET state = 'rotated' WHERE id = $1",
               "waitpoint_response_tokens_rotated_check"},
              {"UPDATE relay.waitpoint_response_tokens SET state = 'unknown' WHERE id = $1",
               "waitpoint_response_tokens_state_check"}
            ] do
          assert sql_error(sql, [token]).postgres.constraint == constraint
        end
      end)
    end
  end
end
