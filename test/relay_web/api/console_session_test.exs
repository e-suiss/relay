defmodule RelayWeb.Api.ConsoleSessionTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp request(method, path, opts) do
    body = Keyword.get(opts, :body)
    raw = if body, do: Jason.encode!(body)
    content = if body, do: [{"content-type", "application/json"}], else: []
    cookies = Keyword.get(opts, :cookies, %{})

    cookies = if opts[:as], do: Map.put(cookies, @session, opts[:as].token), else: cookies

    cookie =
      if cookies == %{},
        do: [],
        else: [{"cookie", Enum.map_join(cookies, "; ", fn {k, v} -> k <> "=" <> v end)}]

    csrf =
      if opts[:as] && method != :get && Keyword.get(opts, :csrf, true),
        do: [{"relay-csrf-token", opts[:as].csrf}],
        else: []

    key = if method != :get, do: [{"idempotency-key", "key-" <> TenantFixture.random()}], else: []

    method
    |> Api.conn(path, raw, content ++ cookie ++ csrf ++ key ++ tenant(opts[:tenant]))
    |> Api.call(RelayWeb.Router)
  end

  defp tenant(nil), do: []

  defp tenant(%Relay.Scope{} = scope) do
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
    login = request(:get, "/v1/operator/session/login?return_to=/console", [])
    [location] = get_resp_header(login, "location")
    flow = login.resp_cookies["relay_operator_login"].value
    claims = %{"sub" => subject, "sid" => "sid-" <> subject, "auth_time" => 0}
    code = FakeAccess.issue("code", claims)
    params = URI.encode_query(%{"code" => code, "state" => query(location)["state"]})

    callback =
      request(:get, "/v1/operator/session/callback?" <> params,
        cookies: %{"relay_operator_login" => flow}
      )

    token = callback.resp_cookies[@session].value
    show = json(request(:get, "/v1/operator/session", cookies: %{@session => token}), 200)
    {:ok, operator_id} = Relay.ExternalId.decode(show["operator"]["id"], ["opr"])
    %{token: token, csrf: show["csrf_token"], operator_id: operator_id, subject: subject}
  end

  defp operator(scope, role) do
    session = sign_in("console-" <> TenantFixture.random())

    {:ok, _row} =
      Admin.assign_role(
        scope,
        %{operator_id: session.operator_id, role: role, reason: "test"},
        TenantFixture.actor(),
        nil
      )

    session
  end

  defp step_up(session) do
    start = request(:post, "/v1/operator/session/step_up", body: %{}, as: session)
    %{"authorization_url" => url} = Jason.decode!(start.resp_body)
    flow = start.resp_cookies["relay_operator_step_up"].value

    code =
      FakeAccess.issue("code", %{
        "sub" => session.subject,
        "auth_time" => 0,
        "acr" => "http://idmanagement.gov/ns/assurance/aal/2",
        "step_up_ref" => "stepup-" <> session.subject
      })

    params = URI.encode_query(%{"code" => code, "state" => query(url)["state"]})

    request(:get, "/v1/operator/session/step_up/callback?" <> params,
      as: session,
      cookies: %{"relay_operator_step_up" => flow}
    )

    session
  end

  defp engage(session, scope, body \\ %{}) do
    body = Map.merge(%{"scope_kind" => "tenant", "reason" => "incident", "ttl" => "PT1H"}, body)

    request(:post, "/v1/kill_switches", body: body, as: session, tenant: scope)
  end

  defp audit_actors(scope, action) do
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

    for row <- rows, row["actor_ref"] != "relay-test", do: row
  end

  describe "X-3 X-4 the console calls the server API with its operator session" do
    test "X-3: a tenant operator reads the selected tenant through the server API", ctx do
      session = operator(ctx.scope, :tenant_operator)
      listed = json(request(:get, "/v1/kill_switches", as: session, tenant: ctx.scope), 200)
      assert listed["data"] == []
      assert json(request(:get, "/v1/notifications", as: session, tenant: ctx.scope), 200)
    end

    test "X-4: the tenant context is required and needs a grant in that tenant", ctx do
      session = operator(ctx.scope, :tenant_operator)

      missing = json(request(:get, "/v1/kill_switches", as: session), 422)
      assert [%{"pointer" => "/headers/relay-tenant"}] = missing["errors"]

      other = TenantFixture.tenant!()
      refused = json(request(:get, "/v1/kill_switches", as: session, tenant: other.live), 403)
      assert refused["code"] == "auth_insufficient_role"

      test_plane = request(:get, "/v1/kill_switches", as: session, tenant: ctx.tenant.test)
      assert json(test_plane, 403)["code"] == "auth_insufficient_role"
    end

    test "X-3: an unknown session is 401 and a mutation without the CSRF token is refused", ctx do
      forged = %{token: "forged", csrf: "x"}

      unknown = request(:get, "/v1/kill_switches", as: forged, tenant: ctx.scope)
      assert json(unknown, 401)["code"] == "auth_invalid_session"

      session = operator(ctx.scope, :tenant_admin)

      conn =
        request(:post, "/v1/kill_switches",
          body: %{},
          as: session,
          tenant: ctx.scope,
          csrf: false
        )

      assert json(conn, 403)["code"] == "auth_csrf_failed"
    end

    test "X-3: an operation of the tenant administrator refuses a tenant operator", ctx do
      session = operator(ctx.scope, :tenant_operator)
      conn = engage(session, ctx.scope, %{"scope_kind" => "workflow", "scope_ref" => "none"})
      assert json(conn, 404)["code"] == "workflow_not_found"

      body = %{"manager" => "panel", "reason" => "x"}
      path = "/v1/workflows/order-shipped/manager"
      denied = request(:post, path, body: body, as: session, tenant: ctx.scope)
      assert json(denied, 403)["code"] == "auth_insufficient_role"
    end

    test "X-3: the API client path is unchanged and refuses operator headers", ctx do
      assert F.body(F.request(:get, "/v1/kill_switches", ctx.token), 200)["data"] == []

      conn = F.request(:get, "/v1/kill_switches", ctx.token, nil, tenant(ctx.scope))
      assert F.body(conn, 422)["code"] == "validation_failed"
    end
  end

  describe "TN-41 TN-22 TN-21 kill switches with the operator session" do
    test "TN-41: a tenant administrator engages a tenant kill switch, a tenant operator may not",
         ctx do
      admin = operator(ctx.scope, :tenant_admin)
      engaged = json(engage(admin, ctx.scope), 201)
      assert engaged["scope_kind"] == "tenant"
      assert engaged["created_by"] == admin.subject

      tenant_operator = operator(ctx.scope, :tenant_operator)
      assert json(engage(tenant_operator, ctx.scope), 403)["code"] == "auth_insufficient_role"

      assert [%{"actor_kind" => "operator"} | _] = audit_actors(ctx.scope, "killswitch.engaged")
    end

    test "TN-22: release needs a fresh step-up and is audited with it", ctx do
      admin = operator(ctx.scope, :tenant_admin)
      engaged = json(engage(admin, ctx.scope), 201)
      path = "/v1/kill_switches/#{engaged["id"]}/release"
      body = %{"reason" => "resolved"}

      refused = request(:post, path, body: body, as: admin, tenant: ctx.scope)
      assert json(refused, 401)["code"] == "auth_step_up_required"

      step_up(admin)
      released = json(request(:post, path, body: body, as: admin, tenant: ctx.scope), 200)
      assert released["status"] == "released"
      assert released["released_by"] == admin.subject

      assert [%{"access_record_ref" => "stepup-" <> _}] =
               audit_actors(ctx.scope, "killswitch.released")

      again = request(:post, path, body: body, as: admin, tenant: ctx.scope)
      assert json(again, 404)["code"] == "kill_switch_not_found"

      client = F.request(:post, path, ctx.token, body)
      assert F.body(client, 403)["code"] == "auth_operator_session_required"
    end

    test "TN-42: stopping security needs a step-up from the operator", ctx do
      admin = operator(ctx.scope, :tenant_admin)
      security = %{"message_class" => "security"}
      assert json(engage(admin, ctx.scope, security), 401)["code"] == "auth_step_up_required"

      step_up(admin)
      assert json(engage(admin, ctx.scope, security), 201)["message_class"] == "security"
    end

    test "TN-22: relaxing a kill switch by replacement asks the operator for a step-up", ctx do
      admin = operator(ctx.scope, :tenant_admin)
      engaged = json(engage(admin, ctx.scope), 201)
      path = "/v1/kill_switches/#{engaged["id"]}/replace"

      body = %{
        "state" => "canary",
        "canary_percent" => 50,
        "reason" => "partial",
        "ttl" => "PT1H"
      }

      refused = request(:post, path, body: body, as: admin, tenant: ctx.scope)
      assert json(refused, 401)["code"] == "auth_step_up_required"

      step_up(admin)
      replaced = json(request(:post, path, body: body, as: admin, tenant: ctx.scope), 201)
      assert replaced["state"] == "canary"
    end

    test "TN-47: a tenant administrator resumes and bulk cancels a released kill switch", ctx do
      admin = step_up(operator(ctx.scope, :tenant_admin))
      engaged = json(engage(admin, ctx.scope), 201)
      id = engaged["id"]
      body = %{"reason" => "done"}

      release = "/v1/kill_switches/#{id}/release"
      json(request(:post, release, body: body, as: admin, tenant: ctx.scope), 200)

      resume = "/v1/kill_switches/#{id}/resume"
      resumed = json(request(:post, resume, body: body, as: admin, tenant: ctx.scope), 200)
      assert %{"action" => "resume", "affected" => 0, "kill_switch_id" => ^id} = resumed

      cancelled =
        request(:post, "/v1/kill_switches/#{id}/cancel_paused",
          body: body,
          as: admin,
          tenant: ctx.scope
        )

      assert %{"action" => "bulk_cancel", "affected" => 0} = json(cancelled, 200)
      assert [_] = audit_actors(ctx.scope, "killswitch.bulk_cancelled")
    end
  end
end
