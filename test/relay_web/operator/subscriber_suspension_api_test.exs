defmodule RelayWeb.Operator.SubscriberSuspensionApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"

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
    assert get_resp_header(callback, "location") == ["/panel"]
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

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    external_id = "user-" <> random()

    body = %{
      "workflow" => "order-shipped",
      "to" => [%{"id" => external_id, "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    F.body(F.request(:post, "/v1/events", token, body), 202)
    {:ok, %{"id" => subscriber}} = Relay.Subscribers.fetch(tenant.live, external_id)
    path = "/v1/operator/subscribers/" <> subscriber
    %{tenant: tenant, scope: tenant.live, external_id: external_id, path: path}
  end

  defp suspended?(ctx) do
    {:ok, subscriber} = Relay.Subscribers.fetch(ctx.scope, ctx.external_id)
    subscriber["state"] == "suspended"
  end

  defp change(ctx, action, session) do
    body = %{"reason" => "support ticket"}
    request(:post, ctx.path <> "/" <> action, body: body, as: session, tenant: ctx.scope)
  end

  defp with_role(ctx, prefix, role), do: grant!(ctx.scope, sign_in(prefix <> random()), role)

  describe "TN-73 TN-22 operator suspension" do
    test "TN-73, TN-22: a tenant operator suspends at once without step-up but cannot resume",
         ctx do
      operator = with_role(ctx, "op-", :tenant_operator)

      body = json(change(ctx, "suspend", operator), 200)
      assert %{"object" => "subscriber_suspension", "suspended" => true, "changed" => true} = body
      assert "sub_" <> _ = body["subscriber_id"]
      assert is_binary(body["suspended_at"])
      assert suspended?(ctx)

      assert json(change(ctx, "resume", operator), 403)["code"] == "auth_insufficient_role"
      assert suspended?(ctx)
    end

    test "TN-73, TN-22: a tenant administrator resumes only after a fresh step-up", ctx do
      admin = with_role(ctx, "admin-", :tenant_admin)

      assert json(change(ctx, "suspend", admin), 200)["suspended"] == true
      assert json(change(ctx, "resume", admin), 401)["code"] == "auth_step_up_required"
      assert suspended?(ctx)

      step_up(admin)
      body = json(change(ctx, "resume", admin), 200)
      assert %{"suspended" => false, "suspended_at" => nil, "changed" => true} = body
      refute suspended?(ctx)
    end

    test "TN-73: an operator without a tenant role is refused and an unknown subscriber is 404",
         ctx do
      outsider = sign_in("op-" <> random())
      assert json(change(ctx, "suspend", outsider), 403)["code"] == "auth_insufficient_role"
      refute suspended?(ctx)

      operator = with_role(ctx, "op-", :tenant_operator)
      unknown = %{ctx | path: "/v1/operator/subscribers/sub_unknown"}
      assert json(change(unknown, "suspend", operator), 404)["code"] == "subscriber_not_found"

      other = Relay.ExternalId.encode("sub", Relay.Id.generate())
      missing = %{ctx | path: "/v1/operator/subscribers/" <> other}
      assert json(change(missing, "suspend", operator), 404)["code"] == "subscriber_not_found"
    end
  end
end
