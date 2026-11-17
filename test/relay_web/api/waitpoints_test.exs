defmodule RelayWeb.Api.WaitpointsTest do
  use Relay.DataCase, async: false

  alias Relay.Api.Waitpoints
  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @hex String.duplicate("ab", 32)
  @digest "sha256:" <> @hex
  @schema %{
    "type" => "object",
    "required" => ["decision"],
    "properties" => %{"decision" => %{"enum" => ["accept", "refuse"]}}
  }
  @actions [%{"id" => "accept", "label" => "Accept"}, %{"id" => "refuse", "label" => "Refuse"}]
  @evidence %{
    "source" => "billing",
    "expected_outcome" => "the order is refunded",
    "harm_if_wrong" => "the amount is lost",
    "fields" => [
      %{"name" => "order", "value" => "A-1"},
      %{"name" => "iban", "digest" => @digest, "sensitive" => true}
    ]
  }
  @events ~w(waitpoint.cancelled waitpoint.created waitpoint.escalated waitpoint.expired
             waitpoint.resolved waitpoint.response_rejected waitpoint.stalled)

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    client = Relay.Id.generate()
    agent = TenantFixture.recipient!(scope, %{}, kind: :agent)
    external_id = "guardian-" <> TenantFixture.random()
    responder = TenantFixture.recipient!(scope, %{}, external_id: external_id)

    %{
      scope: scope,
      token: token(scope, client),
      client: client,
      agent: agent,
      responder: responder,
      external_id: external_id
    }
  end

  defp token(scope, client) do
    opts = [api_client_id: Relay.ExternalId.encode("cli", client)]
    RelayTest.Api.token(scope, ["publish", "read"], opts)
  end

  defp agt(id), do: Relay.ExternalId.encode("agt", id)
  defp cli(id), do: Relay.ExternalId.encode("cli", id)

  defp deadline(scope, seconds) do
    scope
    |> Relay.Clock.business_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp event(ctx, changes \\ %{}) do
    key = "ck-" <> TenantFixture.random()

    Map.merge(
      %{
        "kind" => "event",
        "match" => %{"type" => "refund.decided", "correlation_key" => key},
        "expires_at" => deadline(ctx.scope, 3_600)
      },
      changes
    )
  end

  defp question(ctx, changes \\ %{}) do
    asking = %{
      "kind" => "question",
      "waiter" => %{"kind" => "agent", "id" => agt(ctx.agent)},
      "response_schema" => @schema,
      "responders" => [%{"kind" => "subscriber", "id" => ctx.external_id}],
      "subject_digest" => @digest,
      "content" => %{"action" => "refund", "amount" => "120.00"},
      "actions" => @actions
    }

    event(ctx, Map.merge(asking, changes))
  end

  defp review(ctx, changes \\ %{}) do
    question(ctx, Map.merge(%{"kind" => "review", "evidence" => @evidence}, changes))
  end

  defp create(ctx, body, status \\ 201),
    do: F.body(F.request(:post, "/v1/waitpoints", ctx.token, body), status)

  defp get(ctx, id, status \\ 200),
    do: F.body(F.request(:get, "/v1/waitpoints/" <> id, ctx.token), status)

  defp list(token, query \\ ""),
    do: F.body(F.request(:get, "/v1/waitpoints" <> query, token), 200)

  defp ids(page), do: Enum.map(page["data"], & &1["id"])

  defp cancel(ctx, id, status \\ 200) do
    body = %{"reason" => "done"}
    F.body(F.request(:post, "/v1/waitpoints/#{id}/cancel", ctx.token, body), status)
  end

  defp heartbeat(token, id, status \\ 200),
    do: F.body(F.request(:post, "/v1/waitpoints/#{id}/heartbeat", token), status)

  defp fields(problem) do
    Enum.sort(for error <- problem["errors"], do: {error["pointer"], error["code"]})
  end

  defp uuid(id) do
    {:ok, uuid} = Relay.ExternalId.decode(id, ["wp"])
    uuid
  end

  defp scoped(ctx, sql, params) do
    {:ok, rows} = Repo.in_scope(ctx.scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp mailbox_events(ctx, id) do
    sql = """
    SELECT r.event_type FROM relay.mailbox_records r
    WHERE r.waitpoint_id = $1 ORDER BY r.epoch, r.seq
    """

    ctx |> scoped(sql, [uuid(id)]) |> List.flatten()
  end

  defp advance!(ctx, seconds) do
    digest = TenantFixture.digest()
    actor = TenantFixture.actor()
    advanced = VirtualClock.advance(ctx.scope, seconds * 1_000, digest, actor)
    {:ok, {:advanced, _offset, _now}} = advanced
    :ok = Relay.Agents.run_due(ctx.scope)
  end

  defp value_key!(ctx, recipient) do
    keys = TenantFixture.keys!(ctx.scope)
    class = :notification_content

    {:ok, %{wrapped_dek: wrapped}} =
      Relay.Tenancy.generate_subject_key(ctx.scope, keys.dek_wrap, recipient, class)

    sql = """
    SELECT subject_key_id
    FROM relay_fn.subject_key_create($1, $2, 'notification_content', $3, $4)
    """

    [[key_id]] = scoped(ctx, sql, [Relay.Id.generate(), recipient, wrapped, keys.dek_wrap])
    key_id
  end

  defp respond(ctx, id, changes \\ %{}) do
    recipient = Map.get(changes, :responder_recipient_id, ctx.responder)

    response =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          responder_recipient_id: recipient,
          responder_actor_ref: "acc_user_1",
          session_actor_ref: "acc_user_1",
          via: "push",
          evidence_level: :relay_session,
          subject_digest: Base.decode16!(@hex, case: :lower),
          value_ct: "sealed",
          value_key_id: value_key!(ctx, recipient),
          value_digest: :crypto.hash(:sha256, "value")
        },
        changes
      )

    {:ok, {result, _response_id}} = Relay.Agents.respond(ctx.scope, uuid(id), response)
    result
  end

  describe "AG-8 C-75 interaction kind" do
    test "AG-8: a question is an action_required request with its deadline and actions", ctx do
      body =
        question(ctx, %{
          "labels" => %{"outcome_class" => "reversible", "risk_tier" => "low"},
          "claim_text" => "The customer asked for it",
          "tags" => ["refund"],
          "correlation_id" => "corr-1"
        })

      created = create(ctx, body)

      assert %{
               "object" => "waitpoint",
               "kind" => "question",
               "state" => "open",
               "message_class" => "action_required",
               "response" => nil
             } = created

      assert "wp_" <> _ = created["id"]
      assert created["waiter"] == %{"kind" => "agent", "id" => agt(ctx.agent)}
      assert created["match"] == %{"type" => "refund.decided"}
      assert created["responders"] == [%{"kind" => "subscriber", "id" => ctx.external_id}]
      assert created["labels"] == %{"outcome_class" => "reversible", "risk_tier" => "low"}
      assert created["actions"] == @actions
      assert created["content"] == %{"action" => "refund", "amount" => "120.00"}
      assert created["claim_text"] == "The customer asked for it"
      assert created["subject_digest"] == @digest
      assert created["response_schema"] == @schema
      assert created["correlation_id"] == "corr-1"
      assert created["tags"] == ["refund"]
      assert get(ctx, created["id"]) == created
    end

    test "AG-8: a question or a review without its fields has no waitpoint", ctx do
      asking = ~w(response_schema responders subject_digest content actions)
      problem = create(ctx, Map.drop(question(ctx), asking), 422)

      assert problem["code"] == "validation_failed"
      assert fields(problem) == Enum.sort(for field <- asking, do: {"/" <> field, "required"})

      problem = create(ctx, Map.delete(review(ctx), "evidence"), 422)
      assert fields(problem) == [{"/evidence", "required"}]

      problem = create(ctx, question(ctx, %{"evidence" => @evidence}), 422)
      assert fields(problem) == [{"/evidence", "not_allowed"}]

      problem = create(ctx, question(ctx, %{"responders" => []}), 422)
      assert fields(problem) == [{"/responders", "too_short"}]

      assert list(ctx.token)["data"] == []
    end

    test "AG-8: an event waitpoint carries no class and none of a question's fields", ctx do
      created = create(ctx, event(ctx))

      assert created["kind"] == "event"
      assert created["waiter"] == %{"kind" => "api_client", "id" => cli(ctx.client)}
      refute Map.has_key?(created, "message_class")
      refute Map.has_key?(created, "responders")

      problem = create(ctx, event(ctx, Map.take(question(ctx), ["responders", "actions"])), 422)
      assert fields(problem) == [{"/actions", "not_allowed"}, {"/responders", "not_allowed"}]
    end

    test "AG-8: a review carries its evidence pack and a sensitive value only as a digest",
         ctx do
      created = create(ctx, review(ctx))
      assert created["kind"] == "review"
      assert created["evidence"] == @evidence
      assert get(ctx, created["id"])["evidence"] == @evidence

      sql = "SELECT content_ct FROM relay.waitpoints WHERE id = $1"
      [[sealed]] = scoped(ctx, sql, [uuid(created["id"])])
      assert :binary.match(sealed, "billing") == :nomatch

      bad = [
        %{"name" => "iban", "value" => "TR00", "sensitive" => true},
        %{"name" => "card", "value" => "4111", "digest" => @digest},
        %{"name" => "empty"}
      ]

      problem = create(ctx, review(ctx, %{"evidence" => Map.put(@evidence, "fields", bad)}), 422)

      assert fields(problem) == [
               {"/evidence/fields/0/value", "not_allowed"},
               {"/evidence/fields/1/digest", "conflict"},
               {"/evidence/fields/2/value", "required"}
             ]
    end

    test "AG-7: a waitpoint names existing, active topics for its result", ctx do
      body = %{"key" => "reports:1"}
      F.body(F.request(:post, "/v1/topics", F.token(ctx.scope), body), 201)

      created = create(ctx, event(ctx, %{"deliver_to" => [%{"topic" => "reports:1"}]}))
      assert created["deliver_to"] == [%{"topic" => "reports:1"}]

      problem = create(ctx, event(ctx, %{"deliver_to" => [%{"topic" => "reports:2"}]}), 422)
      assert fields(problem) == [{"/deliver_to/0/topic", "not_found"}]
    end
  end

  describe "AG-12 AG-64 E-47 waiter and responders" do
    test "AG-12: the responder set is stored and returned as it was given", ctx do
      other = TenantFixture.recipient!(ctx.scope, %{}, kind: :agent)

      responders = [
        %{"kind" => "subscriber", "id" => ctx.external_id},
        %{"kind" => "agent", "id" => agt(other)}
      ]

      created = create(ctx, question(ctx, %{"responders" => responders}))
      assert Enum.sort_by(created["responders"], & &1["kind"]) ==
               Enum.sort_by(responders, & &1["kind"])

      sql = "SELECT recipient_id FROM relay.waitpoint_responders WHERE waitpoint_id = $1"
      stored = scoped(ctx, sql, [uuid(created["id"])])
      assert Enum.sort(stored) == Enum.sort([[ctx.responder], [other]])

      unknown = [%{"kind" => "subscriber", "id" => "nobody"}]
      problem = create(ctx, question(ctx, %{"responders" => unknown}), 422)
      assert problem["code"] == "recipient_not_found"
      assert fields(problem) == [{"/responders/0/id", "not_found"}]
    end

    test "INV-31: the waiter is never a responder", ctx do
      waiter = [%{"kind" => "agent", "id" => agt(ctx.agent)}]
      problem = create(ctx, question(ctx, %{"responders" => waiter}), 422)
      assert fields(problem) == [{"/responders", "conflict"}]
    end

    test "E-47: an API client waits like an agent and is named as a waiter only by itself", ctx do
      own = %{"kind" => "api_client", "id" => cli(ctx.client)}
      assert create(ctx, event(ctx, %{"waiter" => own}))["waiter"] == own

      other = %{"kind" => "api_client", "id" => cli(Relay.Id.generate())}
      problem = create(ctx, event(ctx, %{"waiter" => other}), 422)
      assert fields(problem) == [{"/waiter/id", "not_allowed"}]

      missing = %{"kind" => "agent", "id" => agt(Relay.Id.generate())}
      assert create(ctx, event(ctx, %{"waiter" => missing}), 404)["code"] == "agent_not_found"
    end

    test "AG-9: a waiter waits once for an event type and correlation key", ctx do
      body = event(ctx)
      create(ctx, body)
      assert create(ctx, body, 409)["code"] == "resource_conflict"
    end
  end

  describe "AG-53 AG-9 limits in the error body" do
    test "AG-53: a deadline beyond the longest wait is refused with the limit", ctx do
      problem = create(ctx, event(ctx, %{"expires_at" => deadline(ctx.scope, 31 * 86_400)}), 422)

      assert [%{"pointer" => "/expires_at", "code" => "too_long", "limit" => 2_592_000} = error] =
               problem["errors"]

      assert error["actual"] > 2_592_000
      assert error["detail"] =~ "waitpoint.max_wait"

      problem = create(ctx, event(ctx, %{"expires_at" => deadline(ctx.scope, -60)}), 422)
      assert fields(problem) == [{"/expires_at", "too_short"}]
      assert create(ctx, Map.delete(event(ctx), "expires_at"), 422)["code"] == "validation_failed"
    end

    test "AG-53: responders and topics beyond the message limit are refused with the limit",
         ctx do
      responders = for n <- 1..45, do: %{"kind" => "subscriber", "id" => "user-#{n}"}
      topics = for n <- 1..10, do: %{"topic" => "reports:#{n}"}
      body = question(ctx, %{"responders" => responders, "deliver_to" => topics})

      assert [%{"pointer" => "/responders", "code" => "too_long"} = error] =
               create(ctx, body, 422)["errors"]

      assert {error["limit"], error["actual"]} == {50, 55}
      assert error["detail"] =~ "waitpoint.max_messages"
    end

    test "AG-53: a default response over the response size limit is refused with the limit",
         ctx do
      body =
        question(ctx, %{
          "response_schema" => %{"type" => "object"},
          "default_response" => %{"note" => String.duplicate("x", 70_000)}
        })

      assert [%{"pointer" => "/default_response", "code" => "too_long", "limit" => 65_536}] =
               create(ctx, body, 422)["errors"]
    end

    test "AG-53: a refusal of the open waitpoint limits names the limit that was reached", ctx do
      assert Relay.Limits.fetch!(["waitpoint", "max_open_per_environment"]) == 10_000
      assert Relay.Limits.fetch!(["waitpoint", "max_open_per_waiter"]) == 1_000
      create(ctx, question(ctx))

      assert %{limit: 1, limit_name: "waitpoint.max_open_per_waiter"} =
               refusal(ctx, question(ctx), waiter_open_cap: 1)

      assert %{limit: 1, limit_name: "waitpoint.max_open_per_environment"} =
               refusal(ctx, event(ctx), tenant_open_cap: 1)
    end

    defp refusal(ctx, body, caps) do
      {:ok, prepared} = Waitpoints.prepare(ctx.scope, body, %{api_client: ctx.client})
      capped = %{prepared | attrs: Map.merge(prepared.attrs, Map.new(caps))}
      work = fn _status -> Waitpoints.create(ctx.scope, capped) end

      {:ok, {:error, %Relay.Error{code: :waitpoint_limit_reached, details: details}}} =
        Repo.in_scope(ctx.scope, work)

      details
    end
  end

  describe "AG-10 AG-15 INV-32 two timeouts" do
    test "AG-15: a missed heartbeat stalls the waitpoint and the heartbeat opens it again", ctx do
      created = create(ctx, question(ctx, %{"heartbeat_interval" => "PT1M"}))
      assert created["heartbeat_interval"] == "PT1M"
      assert created["heartbeat_due_at"]

      advance!(ctx, 90)
      stalled = get(ctx, created["id"])
      assert stalled["state"] == "stalled"
      assert List.last(mailbox_events(ctx, created["id"])) == "waitpoint.stalled"

      reopened = heartbeat(ctx.token, created["id"])
      assert reopened["state"] == "open"
      assert reopened["heartbeat_due_at"] > stalled["heartbeat_due_at"]
      assert reopened["expires_at"] == created["expires_at"]
    end

    test "AG-10: a stalled waitpoint takes its response", ctx do
      created = create(ctx, question(ctx, %{"heartbeat_interval" => "PT1M"}))
      advance!(ctx, 90)
      assert get(ctx, created["id"])["state"] == "stalled"

      assert respond(ctx, created["id"]) == :resolved
      resolved = get(ctx, created["id"])
      assert resolved["state"] == "resolved"

      assert %{
               "evidence_level" => "relay_session",
               "channel" => "push",
               "responder" => %{"kind" => "subscriber", "external_id" => external_id}
             } = resolved["response"]

      assert external_id == ctx.external_id
      assert "wpr_" <> _ = resolved["response"]["id"]
      refute Map.has_key?(resolved["response"], "approval")
      assert heartbeat(ctx.token, created["id"], 409)["code"] == "waitpoint_closed"
    end

    test "INV-32: the total deadline expires the waitpoint and hands over the default response",
         ctx do
      default = %{"decision" => "refuse"}
      soon = deadline(ctx.scope, 600)
      body = question(ctx, %{"expires_at" => soon, "default_response" => default})
      created = create(ctx, body)
      assert created["default_response"] == default

      advance!(ctx, 601)
      expired = get(ctx, created["id"])
      assert expired["state"] == "expired"
      assert expired["response"] == nil
      assert expired["expires_at"] == created["expires_at"]
      assert mailbox_events(ctx, created["id"]) == ["waitpoint.created", "waitpoint.expired"]

      sql = """
      SELECT r.payload_ct IS NOT NULL FROM relay.mailbox_records r
      WHERE r.waitpoint_id = $1 AND r.event_type = 'waitpoint.expired'
      """

      assert scoped(ctx, sql, [uuid(created["id"])]) == [[true]]
      count = "SELECT count(*) FROM relay.waitpoint_responses WHERE waitpoint_id = $1"
      assert scoped(ctx, count, [uuid(created["id"])]) == [[0]]

      assert respond(ctx, created["id"]) == :rejected_closed
      assert cancel(ctx, created["id"], 409)["code"] == "waitpoint_closed"
    end

    test "AG-15: only the waiter of a waitpoint with a heartbeat sends it", ctx do
      plain = create(ctx, event(ctx))
      assert heartbeat(ctx.token, plain["id"], 409)["code"] == "waitpoint_heartbeat_refused"

      own = create(ctx, event(ctx, %{"heartbeat_interval" => "PT30S"}))
      stranger = token(ctx.scope, Relay.Id.generate())
      assert heartbeat(stranger, own["id"], 409)["code"] == "waitpoint_heartbeat_refused"
      assert heartbeat(ctx.token, own["id"])["state"] == "open"

      problem = create(ctx, event(ctx, %{"heartbeat_interval" => "PT0S"}), 422)
      assert fields(problem) == [{"/heartbeat_interval", "too_short"}]
    end
  end

  describe "INV-31 AG-11 responses" do
    test "INV-31: a foreign response and a response to another subject are rejected and recorded",
         ctx do
      created = create(ctx, question(ctx))
      stranger = TenantFixture.recipient!(ctx.scope, %{})

      assert respond(ctx, created["id"], %{responder_recipient_id: stranger}) ==
               :rejected_not_responder

      other = :crypto.hash(:sha256, "another subject")
      assert respond(ctx, created["id"], %{subject_digest: other}) == :rejected_digest_mismatch
      assert get(ctx, created["id"])["state"] == "open"

      sql = """
      SELECT reason, rule_id FROM relay.waitpoint_response_rejections
      WHERE waitpoint_id = $1 ORDER BY created_at, id
      """

      assert scoped(ctx, sql, [uuid(created["id"])]) == [
               ["not_responder", "waitpoint.response_not_responder"],
               ["digest_mismatch", "waitpoint.response_digest_mismatch"]
             ]

      assert mailbox_events(ctx, created["id"]) == [
               "waitpoint.created",
               "waitpoint.response_rejected",
               "waitpoint.response_rejected"
             ]
    end

    test "AG-11: a resolved waitpoint keeps its response and takes no second one", ctx do
      created = create(ctx, question(ctx))
      assert respond(ctx, created["id"]) == :resolved
      first = get(ctx, created["id"])["response"]

      assert respond(ctx, created["id"]) == :rejected_closed
      assert get(ctx, created["id"])["response"] == first
      value_digest = Base.encode16(:crypto.hash(:sha256, "value"), case: :lower)
      assert first["response_digest"] == "sha256:" <> value_digest
      assert cancel(ctx, created["id"], 409)["code"] == "waitpoint_closed"
    end

    test "INV-31: a response is checked against the response schema before it is recorded" do
      assert Waitpoints.check_response(@schema, %{"decision" => "accept"}) == :ok

      assert {:error, [%{pointer: "/decision", code: "unsupported_value"}]} =
               Waitpoints.check_response(@schema, %{"decision" => "maybe"})

      assert {:error, [%{pointer: "/decision", code: "required"}]} =
               Waitpoints.check_response(@schema, %{})

      large = %{"decision" => "accept", "note" => String.duplicate("x", 70_000)}

      assert {:error, [%{pointer: "", code: "too_long", limit: 65_536}]} =
               Waitpoints.check_response(@schema, large)
    end

    test "INV-31: the response schema is a JSON Schema 2020-12 document the default follows",
         ctx do
      old = Map.put(@schema, "$schema", "http://json-schema.org/draft-07/schema#")
      problem = create(ctx, question(ctx, %{"response_schema" => old}), 422)
      assert fields(problem) == [{"/response_schema", "invalid_format"}]

      problem = create(ctx, question(ctx, %{"default_response" => %{"decision" => "maybe"}}), 422)
      assert fields(problem) == [{"/default_response/decision", "unsupported_value"}]
    end
  end

  describe "AG-46 list, read and cancel" do
    test "AG-46: waitpoints are listed, narrowed and paged, and open to every credential",
         ctx do
      open = create(ctx, question(ctx, %{"tags" => ["refund"]}))
      cancelled = create(ctx, event(ctx))
      cancel(ctx, cancelled["id"])
      stalled = create(ctx, event(ctx, %{"heartbeat_interval" => "PT1M"}))
      advance!(ctx, 90)

      all = [stalled["id"], cancelled["id"], open["id"]]
      assert ids(list(ctx.token)) == all
      assert ids(list(ctx.token, "?awaiting_response=true")) == [stalled["id"], open["id"]]
      assert ids(list(ctx.token, "?state=cancelled")) == [cancelled["id"]]
      assert ids(list(ctx.token, "?state=stalled")) == [stalled["id"]]
      assert ids(list(ctx.token, "?tag=refund")) == [open["id"]]
      assert ids(list(ctx.token, "?waiter=" <> agt(ctx.agent))) == [open["id"]]

      first = list(ctx.token, "?limit=2")
      assert ids(first) == Enum.take(all, 2)
      assert first["has_more"]
      next = "?limit=2&starting_after=" <> first["next_cursor"]
      assert ids(list(ctx.token, next)) == [open["id"]]

      colleague = token(ctx.scope, Relay.Id.generate())
      assert ids(list(colleague, "?awaiting_response=true")) == [stalled["id"], open["id"]]

      other = TenantFixture.tenant!()
      assert ids(list(token(other.test, Relay.Id.generate()))) == []

      conn = F.request(:get, "/v1/waitpoints?state=open&awaiting_response=true", ctx.token)
      assert fields(F.body(conn, 422)) == [{"/awaiting_response", "conflict"}]
    end

    test "AG-46: an open waitpoint is cancelled once and a closed one does not change", ctx do
      created = create(ctx, question(ctx))
      cancelled = cancel(ctx, created["id"])

      assert cancelled["state"] == "cancelled"
      assert cancelled["cancel_reason"] == "done"
      assert cancelled["content"] == created["content"]
      assert cancel(ctx, created["id"], 409)["code"] == "waitpoint_closed"
      assert get(ctx, created["id"]) == cancelled
      assert mailbox_events(ctx, created["id"]) == ["waitpoint.created", "waitpoint.cancelled"]

      missing = Relay.ExternalId.encode("wp", Relay.Id.generate())
      assert get(ctx, missing, 404)["code"] == "waitpoint_not_found"
      assert cancel(ctx, missing, 404)["code"] == "waitpoint_not_found"
      assert heartbeat(ctx.token, missing, 404)["code"] == "waitpoint_not_found"
    end
  end

  describe "AG-16 waitpoint events" do
    test "AG-16: every waitpoint event is in the catalogue" do
      assert @events -- Relay.EventCatalog.names() == []
    end

    test "AG-16: waitpoint events reach the waiter's mailbox and the delivery engine",
         ctx do
      cancelled = create(ctx, question(ctx))
      cancel(ctx, cancelled["id"])
      resolved = create(ctx, question(ctx))
      assert respond(ctx, resolved["id"]) == :resolved

      created = OutboxEvents.data(ctx.scope, "waitpoint.created")
      assert Enum.map(created, & &1["waitpoint_id"]) == [cancelled["id"], resolved["id"]]
      assert Enum.map(created, & &1["kind"]) == ["question", "question"]

      assert OutboxEvents.data(ctx.scope, "waitpoint.cancelled") == [
               %{"waitpoint_id" => cancelled["id"], "kind" => "question", "reason" => "done"}
             ]

      assert [%{"response_id" => "wpr_" <> _} = data] =
               OutboxEvents.data(ctx.scope, "waitpoint.resolved")

      assert data["waitpoint_id"] == resolved["id"]
      assert data["evidence_level"] == "relay_session"
      assert data["subject_digest"] == @digest
      assert data["response_id"] == get(ctx, resolved["id"])["response"]["id"]
      assert mailbox_events(ctx, resolved["id"]) == ["waitpoint.created", "waitpoint.resolved"]
    end
  end

  describe "AG-62 guardian approval" do
    test "AG-62: a guardian approval is a review without a default response", ctx do
      profile = %{"profile" => "guardian_approval"}
      created = create(ctx, review(ctx, profile))
      assert created["profile"] == "guardian_approval"
      assert created["message_class"] == "action_required"
      assert get(ctx, created["id"])["profile"] == "guardian_approval"

      default = Map.put(profile, "default_response", %{"decision" => "refuse"})
      problem = create(ctx, review(ctx, default), 422)
      assert fields(problem) == [{"/default_response", "not_allowed"}]

      problem = create(ctx, question(ctx, profile), 422)
      assert fields(problem) == [{"/profile", "not_allowed"}]

      assert create(ctx, Map.delete(review(ctx, profile), "expires_at"), 422)["code"] ==
               "validation_failed"
    end

    test "AG-62: a guardian approval nobody answers only expires", ctx do
      soon = deadline(ctx.scope, 600)
      body = review(ctx, %{"profile" => "guardian_approval", "expires_at" => soon})
      created = create(ctx, body)

      advance!(ctx, 601)
      expired = get(ctx, created["id"])
      assert expired["state"] == "expired"
      assert expired["response"] == nil
      assert expired["expires_at"] == created["expires_at"]
      refute Map.has_key?(expired, "default_response")
      assert mailbox_events(ctx, created["id"]) == ["waitpoint.created", "waitpoint.expired"]

      sql = """
      SELECT r.payload_ct IS NULL FROM relay.mailbox_records r
      WHERE r.waitpoint_id = $1 AND r.event_type = 'waitpoint.expired'
      """

      assert scoped(ctx, sql, [uuid(created["id"])]) == [[true]]
      assert OutboxEvents.data(ctx.scope, "waitpoint.resolved") == []
    end
  end

  describe "OP-24 subject erasure" do
    test "OP-24: erasing a responder removes the sealed fields of its waitpoint and cancels it",
         ctx do
      :ok = TenantFixture.retention_periods!()
      created = create(ctx, review(ctx, %{"claim_text" => "The customer asked for it"}))
      owner = F.token(ctx.scope)

      F.body(F.request(:delete, "/v1/subscribers/" <> ctx.external_id, owner), 202)
      [[request]] = F.jobs("Relay.Subscribers.Erasure", ctx.scope, "request_id")
      {:ok, request_id} = Relay.Id.parse(request)
      assert {:ok, :completed} = Relay.Subscribers.erase(ctx.scope, request_id, ctx.responder)

      erased = get(ctx, created["id"])
      assert erased["state"] == "cancelled"
      assert erased["cancel_reason"] == "subject_erasure"

      for field <- ~w(content actions evidence claim_text),
          do: refute(Map.has_key?(erased, field), field)

      sql = "SELECT content_ct, claim_text_ct, field_key_id FROM relay.waitpoints WHERE id = $1"
      assert scoped(ctx, sql, [uuid(created["id"])]) == [[nil, nil, nil]]
    end
  end
end
