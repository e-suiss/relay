defmodule Relay.Agents.InvitationDeliveryTest do
  use Relay.DataCase, async: false

  alias Relay.Agents.Live
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  defmodule Minter do
    @moduledoc false

    @spec mint_response_token(Relay.Scope.t(), Relay.Id.t(), Relay.Id.t()) :: {:ok, String.t()}
    def mint_response_token(_scope, _waitpoint_id, _recipient_id),
      do: {:ok, "tok-3f9a1c7e5b2d4a60"}
  end

  @token "tok-3f9a1c7e5b2d4a60"
  @prefix "https://respond.example/r#"
  @access "https://access.example/approve/7f3a"
  @hex String.duplicate("ab", 32)
  @digest "sha256:" <> @hex
  @schema %{
    "type" => "object",
    "required" => ["decision"],
    "properties" => %{"decision" => %{"enum" => ["accept", "refuse"]}}
  }
  @actions [%{"id" => "accept", "label" => "Accept"}, %{"id" => "refuse", "label" => "Refuse"}]
  @evidence %{
    "source" => "shop",
    "expected_outcome" => "the purchase is made",
    "harm_if_wrong" => "the amount is spent"
  }
  @claim "**Approve** <b>now</b> [here](https://evil.example)"
  @neutral "A request is waiting for your response."

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    client = Relay.Id.generate()
    manage = F.token(scope)
    opts = [api_client_id: Relay.ExternalId.encode("cli", client)]
    token = RelayTest.Api.token(scope, ["publish", "read"], opts)
    agent = TenantFixture.recipient!(scope, %{}, kind: :agent)
    external_id = subscriber!(manage)
    {:ok, %{"_id" => responder}} = Relay.Subscribers.fetch(scope, external_id)

    %{
      scope: scope,
      token: token,
      manage: manage,
      agent: agent,
      external_id: external_id,
      responder: responder
    }
  end

  defp subscriber!(token, fields \\ %{"email" => "ayse@example.com"}) do
    external_id = "user-" <> TenantFixture.random()
    body = Map.merge(%{"external_id" => external_id, "locale" => "en"}, fields)
    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    external_id
  end

  defp device!(ctx, external_id \\ nil) do
    body = %{
      "platform" => "fcm",
      "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
      "app" => "com.example.shop",
      "permission" => "granted"
    }

    path = "/v1/subscribers/#{external_id || ctx.external_id}/devices"
    F.body(F.request(:post, path, ctx.manage, body), 201)
  end

  defp deadline(scope) do
    scope
    |> Relay.Clock.business_now()
    |> DateTime.add(3_600, :second)
    |> DateTime.to_iso8601()
  end

  defp question(ctx, changes \\ %{}) do
    Map.merge(
      %{
        "kind" => "question",
        "match" => %{
          "type" => "refund.decided",
          "correlation_key" => "ck-" <> TenantFixture.random()
        },
        "expires_at" => deadline(ctx.scope),
        "waiter" => %{"kind" => "agent", "id" => Relay.ExternalId.encode("agt", ctx.agent)},
        "response_schema" => @schema,
        "responders" => [%{"kind" => "subscriber", "id" => ctx.external_id}],
        "subject_digest" => @digest,
        "content" => %{"action" => "refund", "amount" => "120.00"},
        "actions" => @actions
      },
      changes
    )
  end

  defp create!(ctx, body) do
    created = F.body(F.request(:post, "/v1/waitpoints", ctx.token, body), 201)
    {:ok, id} = Relay.ExternalId.decode(created["id"], ["wp"])
    %{id: id, external: created["id"], view: created}
  end

  defp cancel!(ctx, waitpoint) do
    path = "/v1/waitpoints/#{waitpoint.external}/cancel"
    F.body(F.request(:post, path, ctx.token, %{"reason" => "done"}), 200)
  end

  defp scoped(ctx, sql, params) do
    {:ok, rows} = Repo.in_scope(ctx.scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp invitations(ctx, waitpoint) do
    {:ok, invitations} = Relay.Agents.waitpoint_invitations(ctx.scope, waitpoint.id)
    invitations
  end

  defp invite!(ctx, waitpoint) do
    for %{"state" => "requested", "id" => id} <- invitations(ctx, waitpoint),
        do: assert(:ok = Live.invite(ctx.scope, id))

    :ok
  end

  defp copies(ctx, waitpoint, prefix \\ "waitpoint-invitation:") do
    sql = """
    SELECT d.id, d.channel::text, d.target_id, d.failure_kind, n.message_class::text,
      n.sender_type
    FROM relay.deliveries d
    JOIN relay.notifications n ON n.tenant_id = d.tenant_id AND n.environment = d.environment
      AND n.id = d.notification_id
    WHERE n.subject_type = 'waitpoint' AND n.subject_id = $1 AND n.dedup_key LIKE $2
    ORDER BY d.channel::text, d.id
    """

    for [id, channel, target, failure, class, sender] <-
          scoped(ctx, sql, [Relay.Id.to_string(waitpoint.id), prefix <> "%"]) do
      %{id: id, channel: channel, target: target, failure: failure, class: class, sender: sender}
    end
  end

  defp copy(ctx, waitpoint, channel, prefix \\ "waitpoint-invitation:") do
    [found] = for c <- copies(ctx, waitpoint, prefix), c.channel == channel, do: c
    found
  end

  defp output(ctx, delivery, mode \\ :once) do
    assert {:rendered, content} = Live.content(ctx.scope, delivery.id, mode)
    assert %{"output" => %{} = output} = Jason.decode!(content)
    output
  end

  defp deliver!(ctx, delivery) do
    id = Relay.Id.to_string(delivery.id)
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    Relay.Channels.Live.deliver(ctx.scope, delivery.id, args)
  end

  defp items(ctx) do
    {:ok, snapshot} = Relay.Inbox.snapshot(ctx.scope, ctx.responder)
    snapshot.items
  end

  defp row(output_or_item, key) do
    Enum.find_value(output_or_item["data"], fn row -> if row["key"] == key, do: row["value"] end)
  end

  defp with_tokens do
    previous = Application.get_env(:relay, Live, [])
    Application.put_env(:relay, Live, response_link: @prefix, response_token: Minter)
    on_exit(fn -> Application.put_env(:relay, Live, previous) end)
  end

  describe "AG-28 AG-63 the request goes to every surface" do
    test "AG-28: a request without a surface policy is one action_required notification with a delivery for every device and channel and the inbox record",
         ctx do
      first = device!(ctx)
      second = device!(ctx)
      waitpoint = create!(ctx, question(ctx))

      assert [%{"state" => "requested", "surfaces" => nil, "inbox" => true} = invitation] =
               invitations(ctx, waitpoint)

      assert invitation["source"] == "creation"

      assert F.jobs("Relay.Agents.Live.Invite", ctx.scope, "invitation_id") != []
      assert :ok = invite!(ctx, waitpoint)
      assert :ok = invite!(ctx, waitpoint)

      found = copies(ctx, waitpoint)
      assert Enum.map(found, & &1.channel) == ["email", "in_app", "push", "push"]
      assert Enum.all?(found, &(&1.class == "action_required" and &1.sender == "agent"))

      devices =
        for id <- [first["id"], second["id"]] do
          {:ok, uuid} = Relay.ExternalId.decode(id, ["dev"])
          uuid
        end

      pushed = for %{channel: "push", target: target} <- found, do: target
      assert Enum.sort(pushed) == Enum.sort(devices)

      queued = List.flatten(F.jobs("Relay.Delivery.Send", ctx.scope, "delivery_id"))
      assert Enum.sort(queued) == Enum.sort(Enum.map(found, &Relay.Id.to_string(&1.id)))
    end

    test "AG-28: a guardian request reaches every guardian of the set", ctx do
      other = subscriber!(ctx.manage)

      responders = [
        %{"kind" => "subscriber", "id" => ctx.external_id},
        %{"kind" => "subscriber", "id" => other}
      ]

      body = %{
        "kind" => "review",
        "profile" => "guardian_approval",
        "evidence" => @evidence,
        "responders" => responders
      }

      waitpoint = create!(ctx, question(ctx, body))
      assert length(invitations(ctx, waitpoint)) == 2
      assert :ok = invite!(ctx, waitpoint)
      assert Enum.map(copies(ctx, waitpoint), & &1.channel) == ~w(email email in_app in_app)
    end

    test "AG-63: the inbox record is written and an invitation settles from its delivery", ctx do
      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)
      [%{"id" => invitation}] = invitations(ctx, waitpoint)
      assert {:ok, {:pending, _seconds}} = Live.settle(ctx.scope, invitation)

      assert :ok = deliver!(ctx, copy(ctx, waitpoint, "in_app"))
      assert [item] = items(ctx)
      assert item["title"] == "Decision request"
      assert {:ok, :settled} = Live.settle(ctx.scope, invitation)
      assert [%{"state" => "delivered"}] = invitations(ctx, waitpoint)
      assert {:ok, :done} = Live.settle(ctx.scope, invitation)
    end

    test "AG-63: an invitation that reaches no surface is recorded as unreachable, never held",
         ctx do
      responder = TenantFixture.recipient!(ctx.scope, %{}, kind: :agent)
      agent = %{"kind" => "agent", "id" => Relay.ExternalId.encode("agt", responder)}
      waitpoint = create!(ctx, question(ctx, %{"responders" => [agent]}))
      assert :ok = invite!(ctx, waitpoint)

      assert [%{"state" => "unreachable", "rule_id" => "waitpoint.invitation_unreachable"}] =
               invitations(ctx, waitpoint)

      assert copies(ctx, waitpoint) == []
    end

    test "AG-63: a surface step whose surface the responder lacks is skipped at once while the inbox record is still written",
         ctx do
      policy = %{
        "recipients" => [
          %{
            "responder" => %{"kind" => "subscriber", "id" => ctx.external_id},
            "steps" => [%{"surfaces" => [%{"channel" => "sms"}], "escalate_after" => "PT5M"}]
          }
        ]
      }

      waitpoint = create!(ctx, question(ctx, %{"surface_policy" => policy}))
      assert [%{"surfaces" => [%{"channel" => "sms"}]}] = invitations(ctx, waitpoint)
      assert :ok = invite!(ctx, waitpoint)

      assert [
               %{"state" => "unreachable", "rule_id" => "waitpoint.surface_step_skipped"},
               %{"state" => "requested", "source" => "surface", "inbox" => false}
             ] = invitations(ctx, waitpoint)

      assert Enum.map(copies(ctx, waitpoint), & &1.channel) == ["in_app"]
      assert :ok = invite!(ctx, waitpoint)
      assert Enum.map(copies(ctx, waitpoint), & &1.channel) == ["email", "in_app"]
    end
  end

  describe "AG-29 AG-33 AG-34 the request a human sees" do
    test "AG-29: the text comes from the typed content; the agent's claim is a labelled field of its own and is never rendered",
         ctx do
      device!(ctx)
      waitpoint = create!(ctx, question(ctx, %{"claim_text" => @claim}))
      assert :ok = invite!(ctx, waitpoint)

      email = output(ctx, copy(ctx, waitpoint, "email"))
      assert email["subject"] == "Decision request"
      assert email["text"] =~ "action: refund"
      assert email["text"] =~ "amount: 120.00"
      assert email["text"] =~ "The agent's claim (not verified):"
      assert email["html"] =~ "The agent&#39;s claim" or email["html"] =~ "The agent's claim"
      refute email["html"] =~ "<b>now</b>"
      refute email["html"] =~ ~s(href="https://evil.example")
      refute email["subject"] =~ "Approve"

      item = output(ctx, copy(ctx, waitpoint, "in_app"))
      assert item["title"] == "Decision request"
      assert item["body"] == @neutral
      assert row(item, "agent_claim") == @claim
      assert row(item, "content.action") == "refund"
      assert row(item, "content.amount") == "120.00"
      assert item["actions"] == []
    end

    test "AG-33, CH-67: a push is only an invitation with neutral lock screen text and no action",
         ctx do
      device!(ctx)
      waitpoint = create!(ctx, question(ctx, %{"claim_text" => @claim}))
      assert :ok = invite!(ctx, waitpoint)
      delivery = copy(ctx, waitpoint, "push")

      push = output(ctx, delivery)
      assert push["title"] == "Decision request"
      assert push["body"] == @neutral
      assert push["in_app_body"] =~ "action: refund"
      refute Map.has_key?(push, "actions")
      refute push["payload"] =~ "refund"
      refute push["payload"] =~ "category"
      refute Jason.encode!(push) =~ "Approve"

      {:ok, read} =
        Repo.in_scope(ctx.scope, fn _status ->
          Relay.Channels.Live.Store.delivery(delivery.id)
        end)

      assert read["sensitivity"] == "sensitive"
      assert read["locale"] == "en"
    end

    test "AG-34: the sender type is shown on every surface", ctx do
      device!(ctx)
      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)

      assert output(ctx, copy(ctx, waitpoint, "push"))["subtitle"] == "Sent by an agent"
      assert output(ctx, copy(ctx, waitpoint, "email"))["text"] =~ "Sent by an agent"
      assert row(output(ctx, copy(ctx, waitpoint, "in_app")), "sender_type") == "agent"

      own = create!(ctx, Map.delete(question(ctx), "waiter"))
      assert :ok = invite!(ctx, own)
      assert Enum.all?(copies(ctx, own), &(&1.sender == "system"))
      assert output(ctx, copy(ctx, own, "push"))["subtitle"] == "Sent by a system"
      assert row(output(ctx, copy(ctx, own, "in_app")), "sender_type") == "system"
    end
  end

  describe "AG-32 IN-6 E-16 the approval-type request" do
    test "AG-32, IN-6, E-16: an approval-type item has the deep link to the Access approval surface as its only action and no response link",
         ctx do
      with_tokens()
      device!(ctx)

      body = %{
        "kind" => "review",
        "profile" => "guardian_approval",
        "evidence" => @evidence,
        "access_link" => @access
      }

      waitpoint = create!(ctx, question(ctx, body))
      assert waitpoint.view["access_link"] == @access
      assert :ok = invite!(ctx, waitpoint)

      item = output(ctx, copy(ctx, waitpoint, "in_app"), :verify)
      assert item["title"] == "Approval request"
      assert item["actions"] == [%{"label" => "Open the approval page", "url" => @access}]
      assert item["url"] == @access

      push = output(ctx, copy(ctx, waitpoint, "push"), :verify)
      assert push["url"] == @access

      email = output(ctx, copy(ctx, waitpoint, "email"), :verify)
      assert email["text"] =~ @access
      refute Jason.encode!([item, push, email]) =~ @token
    end

    test "E-16: a question that carries the Access link is approval-type too", ctx do
      with_tokens()
      waitpoint = create!(ctx, question(ctx, %{"access_link" => @access}))
      assert :ok = invite!(ctx, waitpoint)

      item = output(ctx, copy(ctx, waitpoint, "in_app"), :verify)
      assert [%{"url" => @access}] = item["actions"]
      refute Jason.encode!(output(ctx, copy(ctx, waitpoint, "email"), :verify)) =~ @token
    end

    test "AG-32: the Access link is https and an event waitpoint takes none", ctx do
      insecure = question(ctx, %{"access_link" => "http://access.example/approve"})
      F.body(F.request(:post, "/v1/waitpoints", ctx.token, insecure), 422)

      event = %{
        "kind" => "event",
        "match" => %{"type" => "refund.decided", "correlation_key" => "ck-1"},
        "expires_at" => deadline(ctx.scope),
        "access_link" => @access
      }

      F.body(F.request(:post, "/v1/waitpoints", ctx.token, event), 422)
    end
  end

  describe "INV-33 AG-30 the response token" do
    test "INV-33, AG-30, E-71: the response link is written only into the message of a human channel and nothing the waiter reads carries it",
         ctx do
      with_tokens()
      device!(ctx)
      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)

      link = @prefix <> @token
      assert output(ctx, copy(ctx, waitpoint, "email"), :verify)["text"] =~ link
      assert output(ctx, copy(ctx, waitpoint, "push"), :verify)["url"] == link

      refute Jason.encode!(output(ctx, copy(ctx, waitpoint, "email"))) =~ @token
      refute Jason.encode!(output(ctx, copy(ctx, waitpoint, "in_app"), :verify)) =~ @token

      assert :ok = deliver!(ctx, copy(ctx, waitpoint, "in_app"))
      [%{"id" => invitation}] = invitations(ctx, waitpoint)
      assert {:ok, :settled} = Live.settle(ctx.scope, invitation)

      read = F.request(:get, "/v1/waitpoints/" <> waitpoint.external, ctx.token)
      refute read.resp_body =~ @token
      refute read.resp_body =~ "respond.example"

      listed = F.request(:get, "/v1/waitpoints", ctx.token)
      refute listed.resp_body =~ @token

      events = scoped(ctx, "SELECT event_type, payload::text FROM relay.outbox_events", [])
      assert events != []
      refute inspect(events) =~ @token

      records =
        scoped(
          ctx,
          "SELECT to_jsonb(r)::text FROM relay.mailbox_records r WHERE r.waitpoint_id = $1",
          [waitpoint.id]
        )

      assert records != []
      refute inspect(records) =~ @token
      refute inspect(records) =~ "respond.example"
      refute inspect(items(ctx)) =~ @token
    end

    test "AG-30: without a response link address a request is delivered without a link", ctx do
      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)
      email = output(ctx, copy(ctx, waitpoint, "email"), :verify)
      refute email["text"] =~ "Respond"
    end

    test "AG-31: the message of a human channel carries a served, single-use token", ctx do
      previous = Application.get_env(:relay, Live, [])
      Application.put_env(:relay, Live, response_link: @prefix)
      on_exit(fn -> Application.put_env(:relay, Live, previous) end)

      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)
      email = output(ctx, copy(ctx, waitpoint, "email"), :verify)
      assert email["text"] =~ @prefix <> "rt1."

      minted = Relay.Agents.mint_response_token(ctx.scope, waitpoint.id, ctx.responder)
      assert {:ok, "rt1." <> _rest} = minted
      refute Jason.encode!(output(ctx, copy(ctx, waitpoint, "in_app"), :verify)) =~ "rt1."
    end
  end

  describe "AG-63 AG-35 after the waitpoint is closed" do
    test "AG-63, AG-19: no invitation goes out once the waitpoint is closed", ctx do
      waitpoint = create!(ctx, question(ctx))
      cancel!(ctx, waitpoint)

      assert [%{"state" => "cancelled", "id" => invitation}] = invitations(ctx, waitpoint)
      assert :ok = Live.invite(ctx.scope, invitation)
      assert copies(ctx, waitpoint) == []
    end

    test "AG-63, INV-35: a delivery opened before the close is cancelled when its content is asked for, and the close cancels the rest",
         ctx do
      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)
      email = copy(ctx, waitpoint, "email")
      cancel!(ctx, waitpoint)

      assert :done = Live.content(ctx.scope, email.id, :verify)
      assert copy(ctx, waitpoint, "email").failure == "cancelled"

      assert :ok = Live.close(ctx.scope, waitpoint.id)
      assert Enum.all?(copies(ctx, waitpoint), &(&1.failure == "cancelled"))
      assert copies(ctx, waitpoint, "waitpoint-closed:") == []
      assert items(ctx) == []
    end

    test "AG-35: a delivered inbox item is updated to no longer awaiting a response", ctx do
      waitpoint = create!(ctx, question(ctx))
      assert :ok = invite!(ctx, waitpoint)
      assert :ok = deliver!(ctx, copy(ctx, waitpoint, "in_app"))
      assert [%{"title" => "Decision request"} = before] = items(ctx)
      assert row(before, "awaiting_response") == "true"

      cancel!(ctx, waitpoint)
      assert :ok = Live.close(ctx.scope, waitpoint.id)
      assert :ok = Live.close(ctx.scope, waitpoint.id)

      assert [closing] = copies(ctx, waitpoint, "waitpoint-closed:")
      assert closing.channel == "in_app"
      assert closing.sender == "system"
      assert :ok = deliver!(ctx, closing)

      assert [item] = items(ctx)
      assert item["id"] == before["id"]
      assert item["title"] == "Request closed"
      assert item["body"] == "This request is no longer awaiting a response."
      assert item["actions"] == []
      assert row(item, "awaiting_response") == "false"
      assert row(item, "state") == "cancelled"
    end

    test "AG-35: the outbox event of a closed waitpoint derives its closing job", ctx do
      waitpoint = create!(ctx, question(ctx))
      text = Relay.Id.to_string(waitpoint.id)

      {:ok, jobs} =
        Repo.in_scope(ctx.scope, fn _status ->
          for type <- ["waitpoint.cancelled", "waitpoint.created"] do
            Relay.Agents.wake_jobs(%{event_type: type, payload: %{"waitpoint_id" => text}})
          end
        end)

      assert [[%Ecto.Changeset{} = job], []] = jobs
      assert job.changes.worker == "Relay.Agents.Live.Close"
      assert job.changes.args["waitpoint_id"] == text
    end
  end
end
