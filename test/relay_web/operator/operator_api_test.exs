defmodule RelayWeb.Operator.OperatorApiTest do
  use Relay.DataCase, async: true

  import Plug.Conn

  alias Relay.Api.Tenant
  alias Relay.Operators
  alias Relay.Operators.Admin
  alias RelayTest.Api
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

  defp installation_operator(subject) do
    subject
    |> sign_in()
    |> then(&grant!(Operators.installation_scope(), &1, :installation_operator))
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

    for row <- rows do
      Enum.map(
        ~w(tenant_id environment actor_ref on_behalf_of_ref access_record_ref target_id),
        &row[&1]
      )
    end
  end

  defp operator_audit(scope, action),
    do: Enum.reject(audit(scope, action), fn row -> Enum.at(row, 2) == "relay-test" end)

  describe "TN-19 E-26 E-63 login through Access" do
    test "TN-19: login redirects to Access with PKCE and the callback creates the operator and a session" do
      login = request(:get, "/v1/operator/session/login")
      json(login, 302)
      [location] = get_resp_header(login, "location")
      assert String.starts_with?(location, "https://access.test/oauth2/authorize?")
      assert %{"state" => _, "nonce" => _} = query(location)

      session = sign_in("op-" <> TenantFixture.random())
      assert is_binary(session.token) and byte_size(session.csrf) >= 32
    end

    test "TN-19: a callback with another state is refused" do
      login = request(:get, "/v1/operator/session/login")
      flow = login.resp_cookies["relay_operator_login"].value
      code = FakeAccess.issue("code", %{"sub" => "x", "auth_time" => 0})

      conn =
        request(:get, "/v1/operator/session/callback?code=#{code}&state=forged",
          cookies: %{"relay_operator_login" => flow}
        )

      assert json(conn, 401)["code"] == "auth_invalid_token"
    end

    test "TN-19: the configured bootstrap subject becomes the first installation operator" do
      session = sign_in("bootstrap-operator")
      show = json(request(:get, "/v1/operator/session", as: session), 200)
      assert Enum.any?(show["roles"], &(&1["role"] == "installation_operator"))
      assert [_ | _] = audit(Operators.installation_scope(), "role_assignment.created")
    end

    test "E-63: an operator without Relay roles holds no role" do
      session = sign_in("op-" <> TenantFixture.random())
      assert json(request(:get, "/v1/operator/session", as: session), 200)["roles"] == []

      assert json(request(:get, "/v1/operator/tenants", as: session), 403)["code"] ==
               "auth_insufficient_role"
    end

    test "X-3: without a session the operator API answers 401" do
      assert json(request(:get, "/v1/operator/session"), 401)["code"] ==
               "auth_missing_credentials"
    end

    test "TN-19: a sign-out revokes the session" do
      session = sign_in("op-" <> TenantFixture.random())
      json(request(:delete, "/v1/operator/session", as: session), 204)

      assert json(request(:get, "/v1/operator/session", as: session), 401)["code"] ==
               "auth_invalid_session"
    end

    test "X-3: a mutating cookie request without the CSRF token is refused" do
      session = sign_in("op-" <> TenantFixture.random())
      conn = request(:delete, "/v1/operator/session", as: %{session | csrf: "wrong"})
      assert json(conn, 403)["code"] == "auth_csrf_failed"
    end
  end

  describe "TN-20 operator lifecycle from Access" do
    test "TN-20: a user suspended in Access loses every session at once" do
      session = sign_in("op-" <> TenantFixture.random())

      assert {:ok, %{result: :changed, revoked_sessions: 1}} =
               Operators.access_user_changed(session.subject, :suspended, "evt-1")

      assert json(request(:get, "/v1/operator/session", as: session), 401)["code"] ==
               "auth_invalid_session"

      assert [[_, _, "access", _, "evt-1", _]] =
               audit(Operators.installation_scope(), "operator_session.revoked")
               |> Enum.filter(fn row -> Enum.at(row, 5) == session.subject end)
    end

    test "API-79: the owners of a new Access tenant become its administrators" do
      tenant = TenantFixture.tenant!()
      subject = "owner-" <> TenantFixture.random()
      assert :ok = Operators.tenant_owner(tenant.id, subject)
      session = sign_in(subject)
      show = json(request(:get, "/v1/operator/session", as: session), 200)
      assert length(Enum.filter(show["roles"], &(&1["role"] == "tenant_admin"))) == 2
    end
  end

  describe "TN-21 TN-22 E-27 step-up" do
    test "TN-21: a role assignment without a fresh step-up asks for one" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      other = sign_in("other-" <> TenantFixture.random())

      body = %{
        "operator_id" => Relay.ExternalId.encode("opr", other.operator_id),
        "role" => "tenant_operator",
        "reason" => "help"
      }

      conn =
        request(:post, "/v1/operator/role_assignments",
          body: body,
          as: admin,
          tenant: tenant.live
        )

      problem = json(conn, 401)
      assert problem["code"] == "auth_step_up_required"
      assert problem["step_up"]["acr_values"] == "step_up"
      assert [challenge] = get_resp_header(conn, "www-authenticate")
      assert challenge =~ "insufficient_user_authentication"

      step_up(admin)

      created =
        json(
          request(:post, "/v1/operator/role_assignments",
            body: body,
            as: admin,
            tenant: tenant.live
          ),
          201
        )

      assert created["role"] == "tenant_operator"

      assert [[_, _, _, _, "stepup-" <> _, _]] =
               operator_audit(tenant.live, "role_assignment.created")
    end

    test "E-27: Access that cannot decide refuses the operation" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      step_up(admin)
      FakeAccess.decide(:unavailable)

      body = %{
        "operator_id" => Relay.ExternalId.encode("opr", admin.operator_id),
        "role" => "tenant_operator",
        "reason" => "x"
      }

      conn =
        request(:post, "/v1/operator/role_assignments",
          body: body,
          as: admin,
          tenant: tenant.live
        )

      assert json(conn, 503)["code"] == "auth_step_up_unavailable"
      assert operator_audit(tenant.live, "role_assignment.created") == []
    end

    test "TN-21: the last tenant administrator cannot be revoked" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      step_up(admin)

      list =
        json(request(:get, "/v1/operator/role_assignments", as: admin, tenant: tenant.live), 200)

      [%{"id" => id}] = list["data"]

      conn =
        request(:post, "/v1/operator/role_assignments/#{id}/revoke",
          body: %{"reason" => "x"},
          as: admin,
          tenant: tenant.live
        )

      assert json(conn, 409)["code"] == "resource_conflict"
    end

    test "OP-51 TN-22: tightening a send mode is immediate, relaxing needs step-up" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      off = %{"channel" => "email", "mode" => "off", "reason" => "incident"}

      assert json(
               request(:put, "/v1/operator/send_modes",
                 body: off,
                 as: admin,
                 tenant: tenant.live
               ),
               200
             )["mode"] == "off"

      live = %{off | "mode" => "live"}

      assert json(
               request(:put, "/v1/operator/send_modes",
                 body: live,
                 as: admin,
                 tenant: tenant.live
               ),
               401
             )["code"] ==
               "auth_step_up_required"

      step_up(admin)

      json(
        request(:put, "/v1/operator/send_modes", body: live, as: admin, tenant: tenant.live),
        200
      )

      list = json(request(:get, "/v1/operator/send_modes", as: admin, tenant: tenant.live), 200)
      assert %{"level" => "installation"} = hd(list["data"])
      assert length(audit(tenant.live, "send_mode.changed")) == 2
    end
  end

  describe "TN-41 TN-45 platform kill switch" do
    test "TN-41: only the installation operator engages a platform kill switch; release needs step-up" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      body = %{"reason" => "provider outage", "ttl" => "PT1H", "channel" => "sms"}

      assert json(request(:post, "/v1/operator/kill_switches", body: body, as: admin), 403)[
               "code"
             ] ==
               "auth_insufficient_role"

      operator = installation_operator("platform-" <> TenantFixture.random())
      engaged = json(request(:post, "/v1/operator/kill_switches", body: body, as: operator), 201)
      assert engaged["scope_kind"] == "platform"

      list = json(request(:get, "/v1/operator/kill_switches", as: operator), 200)
      assert Enum.any?(list["data"], &(&1["id"] == engaged["id"]))

      release = "/v1/operator/kill_switches/#{engaged["id"]}/release"

      assert json(request(:post, release, body: %{"reason" => "fixed"}, as: operator), 401)[
               "code"
             ] ==
               "auth_step_up_required"

      step_up(operator)
      released = json(request(:post, release, body: %{"reason" => "fixed"}, as: operator), 200)
      assert released["status"] == "released"
    end
  end

  describe "TN-10 TN-71 X-4 TN-23 installation operator" do
    setup do
      TenantFixture.suspension_policy!()
      :ok
    end

    test "TN-10: suspension and resume need step-up and are audited" do
      tenant = TenantFixture.tenant!()
      operator = installation_operator("platform-" <> TenantFixture.random()) |> step_up()
      path = "/v1/operator/tenants/" <> Relay.ExternalId.encode("ten", tenant.id)

      suspended =
        json(
          request(:post, path <> "/suspend",
            body: %{"ground" => "abuse", "reason" => "spam"},
            as: operator
          ),
          201
        )

      assert suspended["state"] == "effective"
      assert {:ok, %{status: :suspended}} = Tenant.edge(tenant.live)

      resumed =
        json(request(:post, path <> "/resume", body: %{"reason" => "appeal"}, as: operator), 200)

      assert resumed["state"] == "lifted"
      assert [_] = audit(tenant.live, "tenant.suspended")
      assert [_] = audit(tenant.live, "tenant.resumed")
    end

    test "TN-71: a suspension on other grounds needs seven days of notice" do
      tenant = TenantFixture.tenant!()
      operator = installation_operator("platform-" <> TenantFixture.random()) |> step_up()
      path = "/v1/operator/tenants/" <> Relay.ExternalId.encode("ten", tenant.id) <> "/suspend"
      soon = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()
      body = %{"ground" => "other", "reason" => "contract", "effective_at" => soon}

      assert json(request(:post, path, body: body, as: operator), 422)["code"] ==
               "validation_failed"

      later = DateTime.utc_now() |> DateTime.add(8 * 86_400, :second) |> DateTime.to_iso8601()

      scheduled =
        json(request(:post, path, body: %{body | "effective_at" => later}, as: operator), 201)

      assert scheduled["state"] == "scheduled"
      assert {:ok, %{status: :active}} = Tenant.edge(tenant.live)
    end

    test "X-4: the cross-tenant overview returns facts and counters only and is audited" do
      tenant = TenantFixture.tenant!()
      operator = installation_operator("platform-" <> TenantFixture.random())
      path = "/v1/operator/tenants/" <> Relay.ExternalId.encode("ten", tenant.id)
      overview = json(request(:get, path, as: operator), 200)
      assert overview["counters"]["notifications_24h"] == 0

      assert Map.keys(overview) --
               ~w(object id access_tenant_id region status platform_product api_version suspensions counters created_at) ==
               []

      assert [_ | _] = audit(Operators.installation_scope(), "cross_tenant.queried")
    end

    test "TN-23: the installation operator cannot read a tenant without a delegation, and reads with one" do
      tenant = TenantFixture.tenant!()
      operator = installation_operator("platform-" <> TenantFixture.random())

      read = fn ->
        request(:get, "/v1/operator/support_delegations", as: operator, tenant: tenant.live)
      end

      assert json(read.(), 403)["code"] == "auth_delegation_required"

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))
        |> step_up()

      body = %{
        "operator_id" => Relay.ExternalId.encode("opr", operator.operator_id),
        "reason" => "ticket 7",
        "duration" => "PT1H"
      }

      granted =
        json(
          request(:post, "/v1/operator/support_delegations",
            body: body,
            as: admin,
            tenant: tenant.live
          ),
          201
        )

      assert granted["access"] == "read"

      assert [%{"id" => id}] = json(read.(), 200)["data"]
      assert id == granted["id"]

      reveal =
        "/v1/operator/subscribers/" <>
          Relay.ExternalId.encode("sub", Relay.Id.generate()) <> "/reveal"

      conn =
        request(:post, reveal,
          body: %{"fields" => ["email"], "reason" => "x"},
          as: operator,
          tenant: tenant.live
        )

      assert json(conn, 403)["code"] == "auth_insufficient_role"

      revoked =
        json(
          request(:post, "/v1/operator/support_delegations/#{id}/revoke",
            body: %{"reason" => "done"},
            as: admin,
            tenant: tenant.live
          ),
          200
        )

      assert revoked["status"] == "revoked"
      assert json(read.(), 403)["code"] == "auth_delegation_required"
    end

    test "X-7: the queue panel link is for installation operators" do
      operator = installation_operator("platform-" <> TenantFixture.random())

      assert json(request(:get, "/v1/operator/queue_panel", as: operator), 200)["url"] ==
               "/v1/operator/queues"
    end
  end

  describe "X-5 TN-47 TN-48 E-31 personal data and audit" do
    test "X-5: each revealed field writes its own pii.revealed record with the step-up reference" do
      tenant = TenantFixture.tenant!()
      keys = TenantFixture.keys!(tenant.live)
      subscriber = TenantFixture.recipient!(tenant.live, keys)

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))
        |> step_up()

      path =
        "/v1/operator/subscribers/" <> Relay.ExternalId.encode("sub", subscriber) <> "/reveal"

      body = %{"fields" => ["email", "name"], "reason" => "support case"}

      revealed = json(request(:post, path, body: body, as: admin, tenant: tenant.live), 200)
      assert length(revealed["audit_ids"]) == 2
      rows = audit(tenant.live, "pii.revealed")
      assert length(rows) == 2

      assert Enum.all?(rows, fn [_, _, actor, _, record, _] ->
               actor == admin.subject and record =~ "stepup-"
             end)
    end

    test "TN-48: the audit log names the operator's Access identity and its read is audited" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      json(
        request(:put, "/v1/operator/send_modes",
          body: %{"mode" => "dry_run", "reason" => "x"},
          as: admin,
          tenant: tenant.live
        ),
        200
      )

      from = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601()
      to = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()
      path = "/v1/operator/audit_log?" <> URI.encode_query(%{"from" => from, "to" => to})
      records = json(request(:get, path, as: admin, tenant: tenant.live), 200)["data"]

      assert Enum.any?(
               records,
               &(&1["action"] == "send_mode.changed" and &1["actor_ref"] == admin.subject)
             )

      assert [_] = audit(tenant.live, "audit_log.read")
    end
  end

  describe "API-13 API-14 operator write replay" do
    test "API-13: a repeated send mode write replays the first response and runs once" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      key = "replay-" <> TenantFixture.random()
      off = %{"channel" => "sms", "mode" => "off", "reason" => "incident"}
      put = fn body ->
        request(:put, "/v1/operator/send_modes",
          body: body,
          as: admin,
          tenant: tenant.live,
          key: key
        )
      end

      first = put.(off)
      assert json(first, 200)["mode"] == "off"
      assert get_resp_header(first, "idempotency-replayed") == []

      again = put.(off)
      assert json(again, 200)["mode"] == "off"
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
      assert get_resp_header(again, "idempotency-key") == [key]
      assert again.resp_body == first.resp_body
      assert length(audit(tenant.live, "send_mode.changed")) == 1

      reused = put.(%{off | "mode" => "dry_run"})
      assert json(reused, 422)["code"] == "idempotency_key_reuse"
      assert length(audit(tenant.live, "send_mode.changed")) == 1
    end

    test "API-13: a repeated API version pin replays the first response" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      key = "replay-" <> TenantFixture.random()
      body = %{"version" => Relay.Api.Versions.latest(), "reason" => "pin"}
      put = fn ->
        request(:put, "/v1/operator/api_version",
          body: body,
          as: admin,
          tenant: tenant.live,
          key: key
        )
      end

      first = put.()
      assert json(first, 200)["pinned"] == body["version"]

      again = put.()
      json(again, 200)
      assert get_resp_header(again, "idempotency-replayed") == ["true"]
      assert again.resp_body == first.resp_body
    end

    test "API-14: a write that fails without side effects leaves the key free for a retry" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      key = "retry-" <> TenantFixture.random()
      bad = %{"version" => "1999-01-01", "reason" => "pin"}
      good = %{bad | "version" => Relay.Api.Versions.latest()}

      put = fn body ->
        request(:put, "/v1/operator/api_version",
          body: body,
          as: admin,
          tenant: tenant.live,
          key: key
        )
      end

      failed = put.(bad)
      assert failed.status in 400..499
      assert get_resp_header(failed, "idempotency-replayed") == []

      retried = put.(good)
      assert json(retried, 200)["pinned"] == good["version"]
      assert get_resp_header(retried, "idempotency-replayed") == []
    end

    test "API-14: a personal data reveal is never replayed" do
      tenant = TenantFixture.tenant!()
      keys = TenantFixture.keys!(tenant.live)
      subscriber = TenantFixture.recipient!(tenant.live, keys)

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))
        |> step_up()

      path =
        "/v1/operator/subscribers/" <> Relay.ExternalId.encode("sub", subscriber) <> "/reveal"

      key = "reveal-" <> TenantFixture.random()
      body = %{"fields" => ["email"], "reason" => "support case"}

      for _round <- 1..2 do
        revealed = request(:post, path, body: body, as: admin, tenant: tenant.live, key: key)
        json(revealed, 200)
        assert get_resp_header(revealed, "idempotency-replayed") == []
      end

      assert length(audit(tenant.live, "pii.revealed")) == 2
    end
  end

  describe "API-52 API version pin" do
    test "API-52: a tenant administrator reads and moves the pin" do
      tenant = TenantFixture.tenant!()

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      assert json(request(:get, "/v1/operator/api_version", as: admin, tenant: tenant.live), 200)[
               "pinned"
             ] == nil

      version = Relay.Api.Versions.latest()

      moved =
        json(
          request(:put, "/v1/operator/api_version",
            body: %{"version" => version, "reason" => "x"},
            as: admin,
            tenant: tenant.live
          ),
          200
        )

      assert moved["pinned"] == version
    end
  end

  defp quota(session, scope, body),
    do: request(:put, "/v1/operator/quotas", body: body, as: session, tenant: scope)

  describe "API-51 TN-52 TN-22 quota policies" do
    test "API-51, TN-22: the installation operator sets the limit; a tenant administrator only tightens at once" do
      tenant = TenantFixture.tenant!()

      operator =
        installation_operator("platform-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      admin =
        sign_in("admin-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      create = %{
        "period" => "day",
        "limit" => 1_000,
        "class_caps" => %{"marketing" => 5_000},
        "reason" => "plan"
      }

      created = json(quota(operator, tenant.live, create), 200)
      assert %{"object" => "quota_policy", "limit" => 1_000, "version" => 1} = created
      assert created["class_caps"] == %{"marketing" => 5_000}

      raise_limit = %{"period" => "day", "limit" => 2_000, "reason" => "upsell"}
      denied = json(quota(admin, tenant.live, raise_limit), 403)
      assert denied["code"] == "auth_insufficient_role"

      lower = %{"period" => "day", "class_caps" => %{"marketing" => 3_000}, "reason" => "x"}
      lowered = json(quota(admin, tenant.live, lower), 200)
      assert lowered["class_caps"] == %{"marketing" => 3_000}
      assert lowered["limit"] == 1_000

      relax = %{"period" => "day", "class_caps" => %{"marketing" => 6_000}, "reason" => "x"}
      assert json(quota(admin, tenant.live, relax), 401)["code"] == "auth_step_up_required"

      step_up(admin)
      assert json(quota(admin, tenant.live, relax), 200)["class_caps"] == %{"marketing" => 6_000}

      listed = json(request(:get, "/v1/operator/quotas", as: admin, tenant: tenant.live), 200)
      assert [%{"period" => "day", "used" => 0, "limit" => 1_000}] = listed["data"]
      assert length(audit(tenant.live, "quota_policy.changed")) == 3
    end

    test "TN-22: removing or raising a policy needs step-up; a new policy needs a limit" do
      tenant = TenantFixture.tenant!()

      operator =
        installation_operator("platform-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      missing = json(quota(operator, tenant.live, %{"period" => "month", "reason" => "x"}), 422)
      assert missing["code"] == "validation_failed"

      body = %{"period" => "month", "limit" => 500, "reason" => "plan"}
      json(quota(operator, tenant.live, body), 200)

      removal = %{"period" => "month", "limit" => nil, "reason" => "drop"}
      assert json(quota(operator, tenant.live, removal), 401)["code"] == "auth_step_up_required"

      step_up(operator)
      json(quota(operator, tenant.live, removal), 200)

      listed = json(request(:get, "/v1/operator/quotas", as: operator, tenant: tenant.live), 200)
      assert listed["data"] == []
    end

    test "API-51: a lowered class cap applies to the next acceptance" do
      tenant = TenantFixture.tenant!()

      operator =
        installation_operator("platform-" <> TenantFixture.random())
        |> then(&grant!(tenant.live, &1, :tenant_admin))

      body = %{"period" => "day", "limit" => 1, "reason" => "tiny"}
      json(quota(operator, tenant.live, body), 200)

      token = RelayTest.IngestFixture.token(tenant.live)
      RelayTest.IngestFixture.workflow!(tenant.live, token, "order-shipped")

      event = fn ->
        RelayTest.IngestFixture.request(:post, "/v1/events", token, %{
          "workflow" => "order-shipped",
          "to" => [%{"id" => "user-" <> random(), "email" => "ayse@example.com"}],
          "data" => %{"order" => "A-1"}
        })
      end

      assert event.().status == 202
      assert json(event.(), 429)["code"] == "quota_exhausted"
    end
  end
end
