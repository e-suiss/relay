defmodule RelayWeb.Api.WaitpointResponsesTest do
  use Relay.DataCase, async: false

  alias Relay.Api.WaitpointResponses
  alias Relay.Operators.AccessDecisionHandler
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  @hex String.duplicate("ab", 32)
  @digest "sha256:" <> @hex
  @schema %{
    "type" => "object",
    "required" => ["decision"],
    "properties" => %{"decision" => %{"enum" => ["accept", "refuse"]}},
    "additionalProperties" => false
  }
  @actions [%{"id" => "accept", "label" => "Accept"}, %{"id" => "refuse", "label" => "Refuse"}]
  @evidence %{
    "source" => "billing",
    "expected_outcome" => "the order is refunded",
    "harm_if_wrong" => "the amount is lost",
    "fields" => [%{"name" => "order", "value" => "A-1"}]
  }
  @receipt ~w(object waitpoint_id status response_id responder evidence_level responded_at
              response_digest)
  @action_schema %{
    "type" => "object",
    "required" => ["action"],
    "properties" => %{"action" => %{"enum" => ["accept", "refuse"]}}
  }
  @accept %{"decision" => "accept"}
  @refuse %{"decision" => "refuse"}

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    client = Relay.Id.generate()
    agent = TenantFixture.recipient!(scope, %{}, kind: :agent)
    external_id = "person-" <> TenantFixture.random()
    responder = TenantFixture.recipient!(scope, %{}, external_id: external_id)
    opts = [api_client_id: Relay.ExternalId.encode("cli", client)]

    %{
      scope: scope,
      token: RelayTest.Api.token(scope, ["publish", "read"], opts),
      agent: agent,
      responder: responder,
      external_id: external_id
    }
  end

  defp question(ctx, changes \\ %{}) do
    deadline = ctx.scope |> Relay.Clock.business_now() |> DateTime.add(3_600, :second)

    body = %{
      "kind" => "question",
      "match" => %{
        "type" => "refund.decided",
        "correlation_key" => "ck-" <> TenantFixture.random()
      },
      "expires_at" => DateTime.to_iso8601(deadline),
      "waiter" => %{"kind" => "agent", "id" => Relay.ExternalId.encode("agt", ctx.agent)},
      "response_schema" => @schema,
      "responders" => [%{"kind" => "subscriber", "id" => ctx.external_id}],
      "subject_digest" => @digest,
      "content" => %{"action" => "refund", "amount" => "120.00"},
      "actions" => @actions
    }

    F.body(F.request(:post, "/v1/waitpoints", ctx.token, Map.merge(body, changes)), 201)["id"]
  end

  defp guardian(ctx) do
    review = %{"kind" => "review", "evidence" => @evidence}
    question(ctx, Map.put(review, "profile", "guardian_approval"))
  end

  defp get(ctx, id), do: F.body(F.request(:get, "/v1/waitpoints/" <> id, ctx.token), 200)

  defp uuid(id) do
    {:ok, uuid} = Relay.ExternalId.decode(id, ["wp"])
    uuid
  end

  defp scoped(ctx, sql, params) do
    {:ok, rows} = Repo.in_scope(ctx.scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp rejections(ctx, id) do
    sql = "SELECT rule_id::text FROM relay.waitpoint_response_rejections WHERE waitpoint_id = $1"
    ctx |> scoped(sql, [uuid(id)]) |> List.flatten() |> Enum.sort()
  end

  defp session(ctx, id, value, responder \\ nil, digest \\ @digest) do
    body = %{"response" => value, "subject_digest" => digest}
    WaitpointResponses.respond(ctx.scope, responder || ctx.responder, uuid(id), body)
  end

  defp mint(ctx, id) do
    Relay.Agents.mint_response_token(ctx.scope, uuid(id), ctx.responder)
  end

  defp channel(token, value, status) do
    body = %{"token" => token, "response" => value, "channel" => "sms"}
    conn = RelayTest.Api.json(:post, "/v1/channel_responses", nil, body, [])
    F.body(RelayTest.Api.call(conn, RelayWeb.Router), status)
  end

  defp page(method, path, body \\ nil) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    RelayTest.Api.call(RelayTest.Api.conn(method, path, body, headers), RelayWeb.Router)
  end

  defp process!(ctx, id) do
    sql = """
    SELECT t.id FROM relay.waitpoint_response_tokens t
    WHERE t.waitpoint_id = $1 AND t.state = 'processing'
    """

    for [token_id] <- scoped(ctx, sql, [uuid(id)]) do
      {:ok, {:settled, outcome}} = Relay.Agents.process_channel_response(ctx.scope, token_id)
      outcome
    end
  end

  defp decision(ctx, id, changes \\ %{}) do
    Map.merge(
      %{
        waitpoint_id: id,
        subject: ctx.external_id,
        value: @accept,
        decision_ref: "aas-decision-1",
        subject_digest: Base.decode16!(@hex, case: :lower),
        source_event_ref: "evt-1"
      },
      changes
    )
  end

  describe "AG-25 AG-26 E-49 a response in a subscriber session" do
    test "AG-25: the response is collected with its record and the waiter reads the value", ctx do
      id = question(ctx)

      assert {:ok, {200, [], receipt}} = session(ctx, id, @accept)
      assert receipt["status"] == "responded"
      assert receipt["evidence_level"] == "relay_session"
      assert receipt["responder"]["external_id"] == ctx.external_id

      resolved = get(ctx, id)
      assert resolved["state"] == "resolved"
      response = resolved["response"]
      assert response["value"] == @accept
      assert response["channel"] == "in_app"
      assert response["evidence_level"] == "relay_session"
      assert response["responder"]["external_id"] == ctx.external_id
      assert response["id"] == receipt["response_id"]
      canonical = :crypto.hash(:sha256, ~s({"decision":"accept"}))
      assert response["response_digest"] == "sha256:" <> Base.encode16(canonical, case: :lower)
      assert is_binary(response["responded_at"])
      refute Map.has_key?(response, "access_decision_ref")
    end

    test "AG-26: the response is a response, never an approval, in every answer and event", ctx do
      id = question(ctx)
      assert {:ok, {200, [], receipt}} = session(ctx, id, @accept)
      assert [data] = OutboxEvents.data(ctx.scope, "waitpoint.resolved")

      for answer <- [receipt, get(ctx, id), data] do
        refute Jason.encode!(answer) =~ "approval"
        refute Jason.encode!(answer) =~ "token"
      end

      assert "sub_" <> _ = data["responder"]["recipient_id"]
      assert data["evidence_level"] == "relay_session"
      assert data["channel"] == "in_app"
      refute Map.has_key?(data, "value")
    end

    test "AG-28: a repeated response changes nothing and another one is rejected and recorded",
         ctx do
      id = question(ctx)
      assert {:ok, {200, [], first}} = session(ctx, id, @accept)
      assert {:ok, {200, [], again}} = session(ctx, id, @accept)
      assert again == first
      assert rejections(ctx, id) == []

      assert {:error, %Relay.Error{code: :waitpoint_closed}} = session(ctx, id, @refuse)
      assert rejections(ctx, id) == ["waitpoint.response_closed"]
      assert get(ctx, id)["response"]["value"] == @accept

      assert [%{"rule_id" => "waitpoint.response_closed"}] =
               OutboxEvents.data(ctx.scope, "waitpoint.response_rejected")
    end
  end

  describe "INV-31 AG-11 validation before anything is recorded" do
    test "INV-31: a value outside the response schema is not written and fails at once", ctx do
      id = question(ctx)

      assert {:error, %Relay.Error{code: :validation_failed, details: %{errors: errors}}} =
               session(ctx, id, %{"decision" => "maybe"})

      assert Enum.all?(errors, &String.starts_with?(&1.pointer, "/response"))
      assert get(ctx, id)["state"] == "open"
      assert rejections(ctx, id) == []
      count = "SELECT count(*) FROM relay.waitpoint_responses WHERE waitpoint_id = $1"
      assert scoped(ctx, count, [uuid(id)]) == [[0]]
    end

    test "AG-11: knowing the waitpoint does not let a stranger respond", ctx do
      id = question(ctx)
      stranger = TenantFixture.recipient!(ctx.scope, %{})

      assert {:error, %Relay.Error{code: :waitpoint_not_found}} =
               session(ctx, id, @accept, stranger)

      assert {:error, %Relay.Error{code: :waitpoint_not_found}} =
               session(ctx, id, @accept, ctx.agent)

      assert rejections(ctx, id) == [
               "waitpoint.response_is_waiter",
               "waitpoint.response_not_responder"
             ]

      assert get(ctx, id)["state"] == "open"
    end

    test "AG-11: a response for another subject is refused and recorded", ctx do
      id = question(ctx)
      other = "sha256:" <> String.duplicate("cd", 32)

      assert {:error, %Relay.Error{code: :waitpoint_response_refused}} =
               session(ctx, id, @accept, nil, other)

      assert rejections(ctx, id) == ["waitpoint.response_digest_mismatch"]
      assert get(ctx, id)["state"] == "open"
    end
  end

  describe "AG-31 AG-35 a response from a channel" do
    test "AG-35: the channel is acknowledged at once and the response processed afterwards",
         ctx do
      id = question(ctx)
      assert {:ok, token} = mint(ctx, id)

      assert %{"status" => "processing", "waitpoint_id" => ^id} = channel(token, @refuse, 202)
      assert get(ctx, id)["state"] == "open"
      assert %{"status" => "processing"} = channel(token, @refuse, 202)

      assert process!(ctx, id) == ["resolved"]
      receipt = channel(token, @refuse, 200)
      assert receipt["status"] == "responded"
      assert receipt["evidence_level"] == "channel_claim"
      assert is_binary(receipt["responded_at"])

      response = get(ctx, id)["response"]
      assert response["value"] == @refuse
      assert response["channel"] == "sms"
      assert response["evidence_level"] == "channel_claim"
    end

    test "AG-31: a token is used once, with one response, and a resend rotates it", ctx do
      id = question(ctx)
      assert {:ok, first} = mint(ctx, id)
      assert {:ok, second} = mint(ctx, id)

      assert channel(first, @accept, 403)["code"] == "response_token_invalid"
      assert channel(second <> "x", @accept, 403)["code"] == "response_token_invalid"
      assert channel("rt1.AAAA.BBBB", @accept, 403)["code"] == "response_token_invalid"

      assert %{"status" => "processing"} = channel(second, @accept, 202)
      assert channel(second, @refuse, 403)["code"] == "response_token_invalid"
      assert process!(ctx, id) == ["resolved"]
      assert get(ctx, id)["response"]["value"] == @accept
    end

    test "INV-31: an invalid value leaves the token unused", ctx do
      id = question(ctx)
      assert {:ok, token} = mint(ctx, id)

      assert channel(token, %{"decision" => "maybe"}, 422)["code"] == "validation_failed"
      assert %{"status" => "processing"} = channel(token, @accept, 202)
    end

    test "AG-28: a token used after the waitpoint was resolved is not awaited any more", ctx do
      id = question(ctx)
      assert {:ok, token} = mint(ctx, id)
      assert {:ok, {200, [], _receipt}} = session(ctx, id, @accept)

      assert %{"status" => "processing"} = channel(token, @refuse, 202)
      assert process!(ctx, id) == ["rejected_closed"]

      assert %{"status" => "not_awaited", "rule_id" => "waitpoint.response_closed"} =
               channel(token, @refuse, 200)

      assert get(ctx, id)["response"]["value"] == @accept
    end

    test "AG-30: what the waiter reads never carries the token", ctx do
      id = question(ctx)
      assert {:ok, token} = mint(ctx, id)
      assert %{"status" => "processing"} = channel(token, @accept, 202)
      assert process!(ctx, id) == ["resolved"]
      [_rt, payload, _mac] = String.split(token, ".")

      events =
        for type <- ["waitpoint.created", "waitpoint.resolved"],
            data <- OutboxEvents.data(ctx.scope, type),
            do: data

      for read <- [get(ctx, id) | events] do
        text = Jason.encode!(read)
        refute text =~ payload
        refute text =~ "token"
      end
    end
  end

  describe "AG-31 AG-35 the page of a response link" do
    test "AG-35: the page shows the actions and takes the chosen one", ctx do
      id = question(ctx, %{"response_schema" => @action_schema})
      assert {:ok, token} = mint(ctx, id)
      path = "/respond/" <> URI.encode_www_form(token)

      shown = page(:get, path)
      assert shown.status == 200
      assert shown.resp_body =~ ~s(value="accept")
      assert shown.resp_body =~ "Refuse"
      assert get(ctx, id)["state"] == "open"

      assert page(:post, path, "action=accept").status == 200
      assert get(ctx, id)["state"] == "open"
      assert process!(ctx, id) == ["resolved"]
      assert get(ctx, id)["response"]["value"] == %{"action" => "accept"}
      assert page(:get, path).resp_body =~ "recorded"
      assert page(:get, "/respond/rt1.AAAA.BBBB").status == 404
    end

    test "INV-31: an action the response schema does not take is refused and the token kept",
         ctx do
      id = question(ctx)
      assert {:ok, token} = mint(ctx, id)
      path = "/respond/" <> URI.encode_www_form(token)

      assert page(:post, path, "action=accept").status == 400
      assert page(:get, path).resp_body =~ ~s(value="accept")
      assert get(ctx, id)["state"] == "open"
    end
  end

  describe "AG-27 AG-62 AG-32 a decision of the Access approval surface" do
    test "AG-27: the decision closes the waitpoint at access_aas_ref with its reference", ctx do
      id = question(ctx)

      assert AccessDecisionHandler.handle_decision(ctx.scope, decision(ctx, id)) == :ok
      assert AccessDecisionHandler.handle_decision(ctx.scope, decision(ctx, id)) == :ok

      response = get(ctx, id)["response"]
      assert response["evidence_level"] == "access_aas_ref"
      assert response["access_decision_ref"] == "aas-decision-1"
      assert response["value"] == @accept
      assert response["channel"] == nil

      assert [data] = OutboxEvents.data(ctx.scope, "waitpoint.resolved")
      assert data["access_decision_ref"] == "aas-decision-1"
    end

    test "AG-62: a guardian approval closes only with the Access decision", ctx do
      id = guardian(ctx)

      assert {:error, %Relay.Error{code: :waitpoint_response_refused}} = session(ctx, id, @accept)
      assert {:error, :profile_refused} = mint(ctx, id)
      assert get(ctx, id)["state"] == "open"
      assert rejections(ctx, id) == ["waitpoint.response_evidence_level"]

      assert AccessDecisionHandler.handle_decision(ctx.scope, decision(ctx, id)) == :ok
      resolved = get(ctx, id)
      assert resolved["state"] == "resolved"
      assert resolved["response"]["evidence_level"] == "access_aas_ref"
    end

    test "AG-27: a decision that does not fit, or names nothing known, is not recorded", ctx do
      id = question(ctx)
      invalid = decision(ctx, id, %{value: %{"decision" => "maybe"}})
      refused = AccessDecisionHandler.handle_decision(ctx.scope, invalid)
      assert refused == {:rejected, "decision_invalid"}

      unknown = decision(ctx, id, %{subject: "nobody-" <> TenantFixture.random()})
      assert AccessDecisionHandler.handle_decision(ctx.scope, unknown) == :unknown

      malformed = decision(ctx, id, %{waitpoint_id: "wp_nope"})

      assert AccessDecisionHandler.handle_decision(ctx.scope, malformed) ==
               {:rejected, "waitpoint_invalid"}

      assert get(ctx, id)["state"] == "open"
    end
  end

  describe "INV-28 INV-29 AG-2 E-57 a response gives no authority" do
    test "INV-28: collecting a response changes no credential, scope or agent state", ctx do
      id = question(ctx)
      before = Relay.Agents.agent_state(ctx.scope, ctx.agent)
      assert {:ok, {200, [], receipt}} = session(ctx, id, @accept)

      assert Relay.Agents.agent_state(ctx.scope, ctx.agent) == before
      assert Map.keys(receipt) -- @receipt == []

      resolved = get(ctx, id)
      refute Enum.any?(Map.keys(resolved), &(&1 =~ ~r/approv|authori|grant|permission/))
      refute Enum.any?(Map.keys(resolved["response"]), &(&1 =~ ~r/approv|authori|grant/))
    end
  end
end
