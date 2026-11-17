defmodule RelayWeb.Api.MailboxMessagesTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @metadata ~w(content_encryption content_marking epoch id mailbox_id object recipient
               relationship sender sent_at seq size trust_label)
  @events "SELECT event_type, payload FROM relay.outbox_events WHERE event_type LIKE 'mailbox.%' ORDER BY created_at, id"
  @record "SELECT kind, delivery_state, payload_ct FROM relay.mailbox_records WHERE id = $1"

  setup do
    :ok = FakeAccess.install!()
    :ok = FakeAccess.publish_first_contact!(nil)
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    ctx = %{tenant: tenant, scope: scope, token: F.token(scope)}
    sender = agent!(ctx)
    recipient = agent!(ctx)
    Map.merge(ctx, %{sender: sender, recipient: recipient})
  end

  defp agent!(ctx) do
    party = "agent-" <> TenantFixture.random()
    body = %{"name" => "One", "owner_ref" => "work:team-7", "access" => %{"party" => party}}
    created = F.body(F.request(:post, "/v1/agents", ctx.token, body), 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["agt"])

    %{
      id: created["id"],
      uuid: id,
      party: party,
      send: credential(ctx, party, ["agent:send"]),
      mailbox: credential(ctx, party, ["agent:mailbox"])
    }
  end

  defp credential(ctx, party, scopes) do
    client = FakeAccess.client!(ctx.scope, scopes)
    access_tenant = ctx.tenant.attrs.access_tenant_id
    claims = %{"sub" => FakeAccess.pairwise(party)}
    FakeAccess.server_token(access_tenant, client, Enum.join(scopes, " "), claims)
  end

  defp envelope(bytes),
    do: %{"content_encryption" => "hpke-x25519-chacha20", "ciphertext" => Base.encode64(bytes)}

  defp send_message(from, to, extra \\ %{}, bytes \\ "sealed between two agents") do
    body = Map.merge(%{"to" => to.id, "encrypted_envelope" => envelope(bytes)}, extra)
    F.request(:post, "/v1/mailbox/messages", from.send, body)
  end

  defp with_token, do: %{"first_contact_token" => FakeAccess.first_contact_token()}

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp relate!(ctx, owner, peer, level, sequence) do
    relationship = %{
      owner: owner.party,
      peer: peer.party,
      level: level,
      sequence: sequence,
      source_event_ref: "evt_" <> TenantFixture.random()
    }

    Relay.Agents.relationship_changed(ctx.scope, relationship)
  end

  defp rows(scope, sql, params \\ []) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp record(ctx, id) do
    {:ok, uuid} = Relay.ExternalId.decode(id, ["mbr"])
    [row] = rows(ctx.scope, @record, [uuid])
    row
  end

  defp reports(ctx) do
    sql = "SELECT payload FROM relay.outbox_events WHERE event_type = 'mailbox.abuse_reported'"
    for [payload] <- rows(ctx.scope, sql), do: Relay.Platform.Envelope.data(payload)
  end

  defp lease(agent),
    do: F.body(F.request(:post, "/v1/mailbox/leases", agent.mailbox, %{"max" => 10}), 200)

  defp requests(agent), do: F.body(F.request(:get, "/v1/mailbox/requests", agent.mailbox), 200)

  defp read_envelope(agent, id),
    do: F.request(:get, "/v1/mailbox/envelopes?record_id=" <> id, agent.mailbox)

  defp block(agent, sender, blocked) do
    body = %{"sender" => sender.id, "blocked" => blocked}
    F.body(F.request(:post, "/v1/mailbox/blocks", agent.mailbox, body), 200)
  end

  describe "AG-60 AG-73 first contact" do
    test "AG-60: a first contact without a token is refused and nothing is recorded", ctx do
      :ok = FakeAccess.publish_first_contact!()

      assert code(send_message(ctx.sender, ctx.recipient), 403) == "first_contact_token_required"

      junk = %{"first_contact_token" => String.duplicate("A", 472)}

      assert code(send_message(ctx.sender, ctx.recipient, junk), 403) ==
               "first_contact_token_required"

      elsewhere = FakeAccess.first_contact_token(origin: "other.example")
      foreign = %{"first_contact_token" => elsewhere}

      assert code(send_message(ctx.sender, ctx.recipient, foreign), 403) ==
               "first_contact_token_required"

      assert requests(ctx.recipient)["data"] == []
      assert rows(ctx.scope, @events) == []
      assert rows(ctx.scope, "SELECT count(*) FROM relay.agent_messages") == [[0]]
      assert rows(ctx.scope, "SELECT count(*) FROM relay.first_contact_tokens") == [[0]]
    end

    test "AG-73: while Access publishes no issuer key a first contact is refused even with a token",
         ctx do
      assert code(send_message(ctx.sender, ctx.recipient, with_token()), 403) ==
               "first_contact_token_required"

      assert {:ok, %{token_keys: []}} = Relay.Access.first_contact_issuer()
      assert rows(ctx.scope, "SELECT count(*) FROM relay.agent_messages") == [[0]]
    end

    test "AG-60, AG-73: a token is spent once and its digest is kept", ctx do
      :ok = FakeAccess.publish_first_contact!()
      token = with_token()

      sent = F.body(send_message(ctx.sender, ctx.recipient, token), 202)
      assert %{"object" => "mailbox_message_receipt", "id" => "mbr_" <> _} = sent

      assert code(send_message(ctx.sender, ctx.recipient, token), 403) ==
               "first_contact_token_required"

      other = agent!(ctx)
      again = send_message(other, ctx.recipient, token)
      assert code(again, 403) == "first_contact_token_required"

      digest =
        :crypto.hash(:sha256, Base.url_decode64!(token["first_contact_token"], padding: false))

      assert [[^digest]] = rows(ctx.scope, "SELECT token_digest FROM relay.first_contact_tokens")
      assert length(requests(ctx.recipient)["data"]) == 1
    end

    test "AG-60: once a relationship exists the token and the first-contact rate are lifted",
         ctx do
      assert {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "known", 1)

      for _n <- 1..3, do: F.body(send_message(ctx.sender, ctx.recipient), 202)

      :ok = FakeAccess.publish_first_contact!()
      F.body(send_message(ctx.sender, ctx.recipient, with_token()), 202)

      assert rows(ctx.scope, "SELECT count(*) FROM relay.first_contact_tokens") == [[0]]
      assert requests(ctx.recipient)["data"] == []
      assert length(lease(ctx.recipient)["records"]) == 4

      assert code(send_message(ctx.recipient, ctx.sender), 403) == "first_contact_token_required"
    end

    test "AG-60, AG-70: the sender's first contacts are limited by the hour", ctx do
      :ok = FakeAccess.publish_first_contact!()
      limit = Relay.Agents.message_limits().messages_per_hour
      assert limit == 20

      for _n <- 1..limit, do: F.body(send_message(ctx.sender, ctx.recipient, with_token()), 202)

      conn = send_message(ctx.sender, ctx.recipient, with_token())
      refused = F.body(conn, 429)

      assert %{"code" => "rate_limited", "limit_name" => "first_contact.messages_per_hour"} =
               refused

      assert refused["limit"] == limit
      assert refused["actual"] == limit
      assert refused["retry_after"] in 1..3600
      assert rows(ctx.scope, "SELECT count(*) FROM relay.first_contact_tokens") == [[limit]]

      assert {:ok, %{over_first_contact_rate: true, relationship: :unknown}} =
               Relay.Agents.sender_standing(ctx.scope, ctx.recipient.uuid, ctx.sender.uuid)

      assert {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "verified", 1)
      F.body(send_message(ctx.sender, ctx.recipient), 202)
    end

    test "AG-60, AG-70: the sender's first contacts are limited by distinct recipients a day",
         ctx do
      :ok = FakeAccess.publish_first_contact!()
      limit = Relay.Agents.message_limits().recipients_per_day
      assert limit == 10

      others = for _n <- 2..limit, do: agent!(ctx)

      for to <- [ctx.recipient | others],
          do: F.body(send_message(ctx.sender, to, with_token()), 202)

      refused = F.body(send_message(ctx.sender, agent!(ctx), with_token()), 429)
      assert refused["limit_name"] == "first_contact.recipients_per_day"
      assert refused["limit"] == limit

      F.body(send_message(ctx.sender, ctx.recipient, with_token()), 202)
    end
  end

  describe "AG-59 request box" do
    test "AG-59: a first contact waits in the request box and triggers nothing", ctx do
      :ok = FakeAccess.publish_first_contact!()
      sent = F.body(send_message(ctx.sender, ctx.recipient, with_token()), 202)

      assert %{"data" => [message]} = requests(ctx.recipient)
      assert message["id"] == sent["id"]
      assert message["relationship"] == "unknown"
      assert message["sender"] == ctx.sender.id
      assert message["recipient"] == ctx.recipient.id

      assert ["request_message", "held", _sealed] = record(ctx, sent["id"])
      assert lease(ctx.recipient)["records"] == []

      listed = F.body(F.request(:get, "/v1/mailbox/records", ctx.recipient.mailbox), 200)
      assert listed["records"] == []

      assert [["mailbox.request_received", payload]] = rows(ctx.scope, @events)
      assert Enum.sort(Map.keys(payload)) == ["kind", "mailbox_id", "record_id"]
      assert rows(ctx.scope, "SELECT count(*) FROM relay.waitpoints") == [[0]]

      assert requests(ctx.sender)["data"] == []
    end

    test "AG-59, AG-73: the relationship copy follows the pair's sequence number", ctx do
      assert {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "trusted", 5)
      assert {:ok, :stale} = relate!(ctx, ctx.recipient, ctx.sender, "unknown", 5)
      assert {:ok, :stale} = relate!(ctx, ctx.recipient, ctx.sender, "unknown", 4)

      assert {:ok, %{relationship: :trusted}} =
               Relay.Agents.sender_standing(ctx.scope, ctx.recipient.uuid, ctx.sender.uuid)

      assert {:ok, %{relationship: :unknown}} =
               Relay.Agents.sender_standing(ctx.scope, ctx.sender.uuid, ctx.recipient.uuid)

      assert {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "unknown", 6)
      assert code(send_message(ctx.sender, ctx.recipient), 403) == "first_contact_token_required"

      stranger = %{party: "agent-" <> TenantFixture.random()}
      assert {:ok, :agent_not_found} = relate!(ctx, ctx.recipient, stranger, "known", 1)
    end

    test "AG-59, AG-73: Access relationship events feed the copy", ctx do
      data = %{
        "tenant" => ctx.tenant.attrs.access_tenant_id,
        "sub" => ctx.recipient.party,
        "peer" => ctx.sender.party,
        "level" => "KNOWN",
        "sequence" => 1
      }

      claims = FakeAccess.event("relationship.updated", data)
      assert FakeAccess.deliver(claims).status == 202
      receipts = Enum.map(FakeAccess.drain!(), &FakeAccess.receipt/1)
      assert %{"state" => "processed"} = Enum.find(receipts, &(&1["webhook_id"] == claims["jti"]))

      F.body(send_message(ctx.sender, ctx.recipient), 202)

      odd = FakeAccess.event("relationship.updated", %{data | "level" => "friend"})
      assert FakeAccess.deliver(odd).status == 202
      receipts = Enum.map(FakeAccess.drain!(), &FakeAccess.receipt/1)

      assert %{"state" => "rejected", "reason" => "invalid_relationship"} =
               Enum.find(receipts, &(&1["webhook_id"] == odd["jti"]))
    end
  end

  describe "AG-56 AG-57 encrypted envelope" do
    test "AG-56, AG-67: Relay records the metadata of an envelope and nothing of its content",
         ctx do
      {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "known", 1)
      bytes = :crypto.strong_rand_bytes(4096)
      sent = F.body(send_message(ctx.sender, ctx.recipient, %{}, bytes), 202)

      assert [%{"id" => id, "kind" => "message"}] = lease(ctx.recipient)["records"]
      assert id == sent["id"]

      read = F.body(read_envelope(ctx.recipient, id), 200)
      assert read["ciphertext"] == Base.encode64(bytes)
      message = read["message"]
      assert Enum.sort(Map.keys(message)) == @metadata
      assert message["size"] == 4096
      assert message["trust_label"] == "authenticated"
      assert message["relationship"] == "known"
      assert message["content_encryption"] == "hpke-x25519-chacha20"
      assert message["content_marking"] == "encrypted_untrusted_content"
      assert message["sender"] == ctx.sender.id

      assert ["message", "leased", sealed] = record(ctx, id)
      assert byte_size(sealed) == 4096 + 29
      refute sealed =~ binary_part(bytes, 0, 64)

      columns =
        rows(
          ctx.scope,
          "SELECT column_name::text FROM information_schema.columns WHERE table_schema = 'relay' AND table_name = 'agent_messages' ORDER BY 1"
        )

      assert List.flatten(columns) ==
               ~w(box content_encryption created_at environment first_contact mailbox_id
                  recipient_agent_id record_created_at record_id relationship sender_agent_id
                  size tenant_id trust_label)
    end

    test "AG-57, AG-21: the wake-up hint of an envelope names the record and nothing else", ctx do
      {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "known", 1)
      F.body(send_message(ctx.sender, ctx.recipient), 202)

      assert [["mailbox.record_appended", payload]] = rows(ctx.scope, @events)
      assert Enum.sort(Map.keys(payload)) == ["kind", "mailbox_id", "record_id"]
      assert payload["kind"] == "message"
      refute Jason.encode!(payload) =~ Relay.Id.to_string(ctx.sender.uuid)
      refute Jason.encode!(payload) =~ ctx.sender.party
    end

    test "AG-57, AG-70: an envelope over the size limit is refused with the limit", ctx do
      {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "known", 1)
      limit = Relay.Agents.message_limits().envelope_max_bytes
      assert limit == 262_144

      F.body(send_message(ctx.sender, ctx.recipient, %{}, :binary.copy("a", limit)), 202)

      refused =
        F.body(send_message(ctx.sender, ctx.recipient, %{}, :binary.copy("a", limit + 1)), 422)

      assert %{"code" => "validation_failed", "limit" => ^limit} = refused
      assert refused["limit_name"] == "encrypted_envelope.max_bytes"
      assert refused["actual"] == limit + 1
    end

    test "AG-56: only the recipient reads an envelope", ctx do
      {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "known", 1)
      sent = F.body(send_message(ctx.sender, ctx.recipient), 202)

      assert code(read_envelope(ctx.sender, sent["id"]), 404) == "mailbox_record_not_found"
      assert code(read_envelope(agent!(ctx), sent["id"]), 404) == "mailbox_record_not_found"

      assert code(F.request(:get, "/v1/mailbox/envelopes", ctx.recipient.mailbox), 422) ==
               "validation_failed"

      denied = F.request(:get, "/v1/mailbox/requests", ctx.recipient.send)
      assert code(denied, 403) == "auth_insufficient_scope"

      body = %{"to" => ctx.recipient.id, "encrypted_envelope" => envelope("x")}
      denied = F.request(:post, "/v1/mailbox/messages", ctx.sender.mailbox, body)
      assert code(denied, 403) == "auth_insufficient_scope"
    end

    test "AG-56: a message to oneself, to an unknown agent or to a suspended one is refused",
         ctx do
      assert code(send_message(ctx.sender, ctx.sender), 422) == "validation_failed"

      nobody = %{id: Relay.ExternalId.encode("agt", Relay.Id.generate())}
      assert code(send_message(ctx.sender, nobody), 404) == "agent_not_found"

      assert :ok ==
               Relay.Agents.agent_access_changed(
                 ctx.scope,
                 :suspended,
                 ctx.recipient.party,
                 "evt_" <> TenantFixture.random()
               )

      assert code(send_message(ctx.sender, ctx.recipient), 409) == "mailbox_inactive"
    end
  end

  describe "AG-61 block and abuse report" do
    test "AG-61: a blocked sender's message is recorded as blocked, wakes nobody and is answered the same",
         ctx do
      {:ok, :applied} = relate!(ctx, ctx.recipient, ctx.sender, "known", 1)

      assert %{"object" => "mailbox_block", "state" => "blocked", "lifted_at" => nil} =
               block(ctx.recipient, ctx.sender, true)

      sent = F.body(send_message(ctx.sender, ctx.recipient), 202)
      assert Enum.sort(Map.keys(sent)) == ["created_at", "id", "object"]

      assert ["blocked_message", "held", _sealed] = record(ctx, sent["id"])
      assert rows(ctx.scope, @events) == []
      assert lease(ctx.recipient)["records"] == []
      assert requests(ctx.recipient)["data"] == []
      assert code(read_envelope(ctx.recipient, sent["id"]), 404) == "mailbox_record_not_found"

      assert [["blocked", "blocked", "known"]] =
               rows(ctx.scope, "SELECT box, trust_label, relationship FROM relay.agent_messages")

      assert {:ok, %{blocked: true}} =
               Relay.Agents.sender_standing(ctx.scope, ctx.recipient.uuid, ctx.sender.uuid)

      assert %{"state" => "lifted"} = block(ctx.recipient, ctx.sender, false)
      F.body(send_message(ctx.sender, ctx.recipient), 202)
      assert length(lease(ctx.recipient)["records"]) == 1
    end

    test "AG-61: a blocked stranger passes the same first-contact checks and stays out of the request box",
         ctx do
      :ok = FakeAccess.publish_first_contact!()
      block(ctx.recipient, ctx.sender, true)

      assert code(send_message(ctx.sender, ctx.recipient), 403) == "first_contact_token_required"

      sent = F.body(send_message(ctx.sender, ctx.recipient, with_token()), 202)
      assert ["blocked_message", "held", _sealed] = record(ctx, sent["id"])
      assert requests(ctx.recipient)["data"] == []
      assert rows(ctx.scope, @events) == []

      body = %{"sender" => ctx.recipient.id, "blocked" => true}
      own = F.request(:post, "/v1/mailbox/blocks", ctx.recipient.mailbox, body)
      assert code(own, 422) == "validation_failed"
    end

    test "AG-61: an abuse report carries metadata and the reporter's statement, marked unverified",
         ctx do
      :ok = FakeAccess.publish_first_contact!()
      secret = "sealed words nobody at Relay reads"
      sent = F.body(send_message(ctx.sender, ctx.recipient, with_token(), secret), 202)

      body = %{"record_id" => sent["id"], "statement" => "it asked for my password"}
      path = "/v1/mailbox/abuse_reports"
      report = F.body(F.request(:post, path, ctx.recipient.mailbox, body), 200)

      assert %{"object" => "mailbox_abuse_report", "statement_attached" => true} = report
      assert report["record_id"] == sent["id"]

      assert [data] = reports(ctx)
      assert data["record_id"] == sent["id"]
      assert data["sender_ref"] == ctx.sender.id
      assert data["size"] == byte_size(secret)
      assert data["rate"] == %{"messages_last_hour" => 1, "recipients_last_day" => 1}

      assert data["statement"] == %{
               "marking" => "reporter_statement_unverified",
               "content" => "it asked for my password"
             }

      refute Jason.encode!(data) =~ secret

      bare = %{"record_id" => sent["id"]}
      again = F.body(F.request(:post, path, ctx.recipient.mailbox, bare), 200)
      assert again["reported_at"] == report["reported_at"]
      assert again["statement_attached"] == true
      assert length(reports(ctx)) == 1

      theirs = F.request(:post, path, ctx.sender.mailbox, %{"record_id" => sent["id"]})
      assert code(theirs, 404) == "mailbox_record_not_found"
    end
  end
end
