defmodule RelayWeb.Operator.TakedownApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Operators
  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"
  @path "/v1/operator/takedowns"

  defp request(method, path, opts \\ []) do
    body = Keyword.get(opts, :body)
    raw = if body, do: Jason.encode!(body)
    content = if body, do: [{"content-type", "application/json"}], else: []

    cookies =
      opts
      |> Keyword.get(:cookies, %{})
      |> Map.merge(if opts[:as], do: %{@session => opts[:as].token}, else: %{})

    cookie = if cookies == %{}, do: [], else: [{"cookie", cookie_header(cookies)}]
    csrf = if opts[:as] && method != :get, do: [{"relay-csrf-token", opts[:as].csrf}], else: []
    key = if method != :get, do: [{"idempotency-key", opts[:key] || "key-" <> random()}], else: []
    tenant = tenant_headers(opts[:tenant])

    method
    |> Api.conn(
      path,
      raw,
      content ++ cookie ++ csrf ++ key ++ tenant ++ Keyword.get(opts, :headers, [])
    )
    |> Api.call(RelayWeb.Router)
  end

  defp random, do: TenantFixture.random()

  defp cookie_header(cookies), do: Enum.map_join(cookies, "; ", fn {k, v} -> k <> "=" <> v end)

  defp tenant_headers(nil), do: []

  defp tenant_headers(%Relay.Scope{} = scope) do
    [
      {"relay-tenant", Relay.ExternalId.encode("ten", scope.tenant_id)},
      {"relay-environment", Atom.to_string(scope.environment)}
    ]
  end

  defp json(conn, status) do
    assert conn.status == status, conn.resp_body
    Api.assert_contract(conn)
    if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
  end

  defp query(location), do: location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp sign_in(subject) do
    login = request(:get, "/v1/operator/session/login?return_to=/panel")
    json(login, 302)
    [location] = get_resp_header(login, "location")
    state = query(location)["state"]
    flow = login.resp_cookies["relay_operator_login"].value

    code =
      FakeAccess.issue("code", %{"sub" => subject, "sid" => "sid-" <> subject, "auth_time" => 0})

    callback =
      request(
        :get,
        "/v1/operator/session/callback?" <> URI.encode_query(%{"code" => code, "state" => state}),
        cookies: %{"relay_operator_login" => flow}
      )

    json(callback, 302)
    token = callback.resp_cookies[@session].value
    show = json(request(:get, "/v1/operator/session", cookies: %{@session => token}), 200)
    {:ok, operator_id} = Relay.ExternalId.decode(show["operator"]["id"], ["opr"])
    %{token: token, csrf: show["csrf_token"], operator_id: operator_id, subject: subject}
  end

  defp step_up(session) do
    start = request(:post, "/v1/operator/session/step_up", body: %{}, as: session)
    %{"authorization_url" => url} = json(start, 200)
    state = query(url)["state"]
    flow = start.resp_cookies["relay_operator_step_up"].value

    code =
      FakeAccess.issue("code", %{
        "sub" => session.subject,
        "auth_time" => 0,
        "acr" => "step_up",
        "step_up_ref" => "stepup-" <> session.subject
      })

    done =
      request(
        :get,
        "/v1/operator/session/step_up/callback?" <>
          URI.encode_query(%{"code" => code, "state" => state}),
        as: session,
        cookies: %{"relay_operator_step_up" => flow}
      )

    json(done, 302)
    session
  end

  defp grant!(scope, session, role) do
    {:ok, _row} =
      Admin.assign_role(
        scope,
        %{operator_id: session.operator_id, role: role, reason: "test"},
        TenantFixture.actor(),
        nil
      )

    session
  end

  defp installation_operator do
    session = sign_in("platform-" <> random())
    grant!(Operators.installation_scope(), session, :installation_operator)
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status -> Relay.Repo.scoped_query!(sql, params).rows end)

    rows
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    for row <- rows, do: {row["access_record_ref"], row["target_id"]}
  end

  defp send!(ctx, workflow, to) do
    body = %{"workflow" => workflow, "to" => [to], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    {notification, delivery_id}
  end

  defp deliver!(ctx, delivery_id) do
    id = Relay.Id.to_string(delivery_id)
    args = Map.put(Relay.Scope.to_job_args(ctx.scope), "delivery_id", id)
    Relay.Delivery.Send.perform(%Oban.Job{args: args})
    :ok = Relay.Channels.Live.deliver(ctx.scope, delivery_id, args)
  end

  defp take_down(ctx, type, id, session) do
    body = %{"target" => %{"type" => type, "id" => id}, "reason" => "court order 2026/1"}
    request(:post, @path, body: body, as: session, tenant: ctx.scope)
  end

  defp lift(ctx, takedown, session) do
    path = @path <> "/" <> takedown["id"] <> "/lift"
    request(:post, path, body: %{"reason" => "order withdrawn"}, as: session, tenant: ctx.scope)
  end

  defp ref(session), do: "stepup-" <> session.subject

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    %{tenant: tenant, scope: scope, token: F.token(scope)}
  end

  describe "TN-60 TN-21 TN-47 takedown of a message" do
    test "TN-60, TN-21: a takedown needs the installation operator and a fresh step-up", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      to = %{"id" => "user-" <> random(), "email" => "ayse@example.com"}
      {notification, delivery_id} = send!(ctx, "order-shipped", to)

      admin = step_up(grant!(ctx.scope, sign_in("admin-" <> random()), :tenant_admin))
      refused = json(take_down(ctx, "message", notification, admin), 403)
      assert refused["code"] == "auth_insufficient_role"

      platform = installation_operator()
      stale = json(take_down(ctx, "message", notification, platform), 401)
      assert stale["code"] == "auth_step_up_required"

      pending = "SELECT failure_kind FROM relay.deliveries WHERE id = $1"
      assert sql!(ctx.scope, pending, [delivery_id]) == [[nil]]
      assert sql!(ctx.scope, "SELECT count(*)::integer FROM relay.takedowns", []) == [[0]]
      assert audit(ctx.scope, "takedown.applied") == []
    end

    test "TN-60, TN-47: pending deliveries are cancelled with the takedown rule and the takedown is audited",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      to = %{"id" => "user-" <> random(), "email" => "ayse@example.com"}
      {notification, delivery_id} = send!(ctx, "order-shipped", to)
      platform = step_up(installation_operator())

      takedown = json(take_down(ctx, "message", notification, platform), 201)

      assert %{
               "object" => "takedown",
               "state" => "active",
               "target" => %{"type" => "message", "id" => ^notification},
               "cancelled_deliveries" => 1,
               "hidden_inbox_items" => 0,
               "lifted_at" => nil
             } = takedown

      assert "tkd_" <> _ = takedown["id"]
      {:ok, id} = Relay.ExternalId.decode(takedown["id"], ["tkd"])
      rule = "takedown.message:" <> Relay.Id.to_string(id)

      cancelled = "SELECT failure_kind, failure_rule_id FROM relay.deliveries WHERE id = $1"
      assert sql!(ctx.scope, cancelled, [delivery_id]) == [["cancelled", rule]]
      assert {:ok, "taken_down"} = Relay.Rules.reason(rule)

      {:ok, notification_id} = Relay.ExternalId.decode(notification, ["ntf"])
      closed = "SELECT state, close_rule_id FROM relay.notifications WHERE id = $1"
      assert sql!(ctx.scope, closed, [notification_id]) == [["cancelled", rule]]

      assert audit(ctx.scope, "takedown.applied") == [{ref(platform), Relay.Id.to_string(id)}]

      again = json(take_down(ctx, "message", notification, platform), 200)
      assert again["id"] == takedown["id"]
      assert length(audit(ctx.scope, "takedown.applied")) == 1

      listed = json(request(:get, @path, as: platform, tenant: ctx.scope), 200)
      assert Enum.map(listed["data"], & &1["id"]) == [takedown["id"]]
    end

    test "TN-60: the inbox item of a message is hidden and shown again when the takedown is lifted",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["in_app"])
      {notification, delivery_id} = send!(ctx, "order-shipped", %{"id" => "user-" <> random()})
      deliver!(ctx, delivery_id)
      state = "SELECT hidden_at IS NOT NULL, hidden_reason FROM relay.inbox_items"
      assert sql!(ctx.scope, state, []) == [[false, nil]]

      platform = step_up(installation_operator())
      takedown = json(take_down(ctx, "message", notification, platform), 201)
      assert takedown["hidden_inbox_items"] == 1
      assert sql!(ctx.scope, state, []) == [[true, "takedown"]]

      lifted = json(lift(ctx, takedown, platform), 200)
      assert %{"state" => "lifted", "lift_reason" => "order withdrawn"} = lifted
      assert is_binary(lifted["lifted_at"])
      assert sql!(ctx.scope, state, []) == [[false, nil]]

      {:ok, id} = Relay.ExternalId.decode(takedown["id"], ["tkd"])
      assert audit(ctx.scope, "takedown.lifted") == [{ref(platform), Relay.Id.to_string(id)}]

      assert json(lift(ctx, takedown, platform), 200)["state"] == "lifted"
      assert length(audit(ctx.scope, "takedown.lifted")) == 1
    end
  end

  describe "TN-60 TN-21 TN-47 takedown of a template" do
    test "TN-60: a template is unpublished by archiving it and is live again once lifted", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      template = "SELECT id, state, live_version_id IS NOT NULL FROM relay.templates"
      [[id, "active", true]] = sql!(ctx.scope, template, [])
      external = Relay.ExternalId.encode("tpl", id)

      platform = installation_operator()
      stale = json(take_down(ctx, "template", external, platform), 401)
      assert stale["code"] == "auth_step_up_required"
      step_up(platform)

      takedown = json(take_down(ctx, "template", external, platform), 201)
      assert takedown["target"] == %{"type" => "template", "id" => external}
      assert sql!(ctx.scope, template, []) == [[id, "archived", true]]
      assert [{_ref, _id}] = audit(ctx.scope, "takedown.applied")

      assert json(lift(ctx, takedown, platform), 200)["state"] == "lifted"
      assert sql!(ctx.scope, template, []) == [[id, "active", true]]
      assert [{_ref, _id}] = audit(ctx.scope, "takedown.lifted")
    end

    test "TN-60: an unknown target and an unknown takedown are 404", ctx do
      platform = step_up(installation_operator())
      template = Relay.ExternalId.encode("tpl", Relay.Id.generate())
      missing = json(take_down(ctx, "template", template, platform), 404)
      assert missing["code"] == "template_not_found"

      message = Relay.ExternalId.encode("ntf", Relay.Id.generate())
      missing = json(take_down(ctx, "message", message, platform), 404)
      assert missing["code"] == "notification_not_found"

      mismatched = json(take_down(ctx, "sender_identity", template, platform), 422)
      assert [%{"pointer" => "/target/id"}] = mismatched["errors"]

      unknown = %{"id" => Relay.ExternalId.encode("tkd", Relay.Id.generate())}
      assert json(lift(ctx, unknown, platform), 404)["code"] == "takedown_not_found"
    end

    test "TN-60, TN-16: a takedown and its target are not found from another tenant", ctx do
      F.workflow!(ctx.scope, ctx.token, "order-shipped")
      [[id]] = sql!(ctx.scope, "SELECT id FROM relay.templates", [])
      external = Relay.ExternalId.encode("tpl", id)
      platform = step_up(installation_operator())
      other = %{ctx | scope: TenantFixture.tenant!().live}

      missing = json(take_down(other, "template", external, platform), 404)
      assert missing["code"] == "template_not_found"

      takedown = json(take_down(ctx, "template", external, platform), 201)
      assert json(lift(other, takedown, platform), 404)["code"] == "takedown_not_found"
      assert json(request(:get, @path, as: platform, tenant: other.scope), 200)["data"] == []
      assert sql!(ctx.scope, "SELECT state FROM relay.takedowns", []) == [["active"]]
    end
  end

  describe "TN-60 TN-21 TN-47 takedown of a sender identity" do
    setup ctx do
      account = Relay.Id.generate()
      id = Relay.Id.generate()
      actor = TenantFixture.actor()

      attrs = %{
        id: account,
        channel: "sms",
        provider: "fake",
        ownership: "shared",
        role: "primary",
        priority: 0,
        in_installation: true,
        transfer_basis: "none"
      }

      {:ok, {:created, 1}} =
        Relay.Channels.put_account(ctx.scope, attrs, TenantFixture.digest(), actor)

      sender = %{
        id: id,
        provider_account_id: account,
        channel: "sms",
        kind: "sms_sender",
        value: "RELAY",
        approval_state: "approved"
      }

      {:ok, {:created, 1}} =
        Relay.Channels.put_sender_identity(ctx.scope, sender, TenantFixture.digest(), actor)

      %{sender_id: id, sender: Relay.ExternalId.encode("snd", id)}
    end

    test "TN-60, TN-21, TN-47: a sender identity is suspended with the takedown rule and resumed by lifting",
         ctx do
      state = "SELECT suspended_at IS NOT NULL, suspension_rule_id FROM relay.sender_identities"
      platform = installation_operator()
      stale = json(take_down(ctx, "sender_identity", ctx.sender, platform), 401)
      assert stale["code"] == "auth_step_up_required"
      assert sql!(ctx.scope, state, []) == [[false, nil]]
      step_up(platform)

      takedown = json(take_down(ctx, "sender_identity", ctx.sender, platform), 201)
      assert takedown["target"] == %{"type" => "sender_identity", "id" => ctx.sender}
      assert sql!(ctx.scope, state, []) == [[true, "takedown.sender_identity"]]
      assert {:ok, "taken_down"} = Relay.Rules.reason("takedown.sender_identity")
      assert [{ref, _id}] = audit(ctx.scope, "takedown.applied")
      assert ref == ref(platform)

      assert json(lift(ctx, takedown, platform), 200)["state"] == "lifted"
      assert sql!(ctx.scope, state, []) == [[false, nil]]
      assert [{^ref, _id}] = audit(ctx.scope, "takedown.lifted")
    end

    test "TN-60: lifting leaves a sender identity suspended that was suspended before the takedown",
         ctx do
      {:ok, _changed} =
        Relay.Channels.suspend_sender_identity(
          ctx.scope,
          ctx.sender_id,
          true,
          "channel.sender_unapproved",
          TenantFixture.digest(),
          TenantFixture.actor()
        )

      state = "SELECT suspended_at IS NOT NULL, suspension_rule_id FROM relay.sender_identities"
      platform = step_up(installation_operator())
      takedown = json(take_down(ctx, "sender_identity", ctx.sender, platform), 201)
      assert sql!(ctx.scope, state, []) == [[true, "channel.sender_unapproved"]]
      assert json(lift(ctx, takedown, platform), 200)["state"] == "lifted"
      assert sql!(ctx.scope, state, []) == [[true, "channel.sender_unapproved"]]
    end
  end
end
