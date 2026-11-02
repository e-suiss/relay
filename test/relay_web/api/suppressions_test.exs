defmodule RelayWeb.Api.SuppressionsTest do
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
    %{tenant: tenant, scope: tenant.live, token: F.token(tenant.live)}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp suppress(token, body, headers \\ []),
    do: F.request(:post, "/v1/suppressions", token, body, headers)

  defp address(channel, address), do: %{"channel" => channel, "address" => address}

  defp lift(token, id, reason \\ "the customer asked"),
    do: F.request(:post, "/v1/suppressions/#{id}/lift", token, %{"reason" => reason})

  defp bounced!(scope, address, reason) do
    {:ok, digests} = Relay.Preferences.address_digests(scope, "email", address)
    attrs = %{channel: "email", digests: digests, reason: reason, expires_at: nil}

    {:ok, {:added, id}} =
      Relay.Preferences.in_scope(scope, fn _status ->
        Relay.Preferences.add_suppression(scope, attrs, TenantFixture.actor())
      end)

    Relay.ExternalId.encode("sup", id)
  end

  defp matches(scope, address) do
    {:ok, digests} = Relay.Preferences.address_digests(scope, "email", address)

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!("relay_fn.suppression_match", ["email", Enum.map(digests, &elem(&1, 1))])
      end)

    Enum.map(rows, & &1["reason"])
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())]
        )
      end)

    for row <- rows, do: Map.take(row, ~w(actor_kind actor_ref target_type target_id))
  end

  describe "PC-59 suppressions" do
    test "PC-59, OP-20: an address is suppressed by its digest, never returned, and only once",
         ctx do
      conn = suppress(ctx.token, %{"channel" => "email", "address" => " Ayse@Example.com "})
      body = F.body(conn, 201)

      assert "sup_" <> _ = body["id"]

      assert %{
               "object" => "suppression",
               "channel" => "email",
               "reason" => "manual",
               "state" => "active",
               "expires_at" => nil,
               "lifted_at" => nil,
               "lifted_by" => nil,
               "lift_reason" => nil
             } = body

      refute conn.resp_body =~ "example.com"
      assert matches(ctx.scope, "ayse@example.com") == ["manual"]

      lower = %{"channel" => "email", "address" => "ayse@example.com"}
      again = F.body(suppress(ctx.token, lower), 200)
      assert again["id"] == body["id"]
      assert [%{"target_type" => "suppression"}] = audit(ctx.scope, "suppression.added")
    end

    test "PC-59: only a manual suppression expires, in the future; the address fits its channel",
         ctx do
      past = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))
      future = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3_600))

      invalid = %{"channel" => "email", "address" => "a@example.com", "reason" => "invalid"}
      problem = F.body(suppress(ctx.token, Map.put(invalid, "expires_at", future)), 422)
      assert [%{"pointer" => "/expires_at", "code" => "not_allowed"}] = problem["errors"]

      manual = %{"channel" => "email", "address" => "a@example.com", "expires_at" => past}
      problem = F.body(suppress(ctx.token, manual), 422)
      assert [%{"pointer" => "/expires_at"}] = problem["errors"]

      phone = %{"channel" => "sms", "address" => "not a number"}
      problem = F.body(suppress(ctx.token, phone), 422)
      assert [%{"pointer" => "/address", "code" => "invalid_format"}] = problem["errors"]

      timed = F.body(suppress(ctx.token, %{manual | "expires_at" => future}), 201)
      assert timed["state"] == "active"
      assert is_binary(timed["expires_at"])
      assert F.body(suppress(ctx.token, invalid), 201)["reason"] == "invalid"
    end

    test "PC-59, API-56: suppressions are listed newest first with filters", ctx do
      email = F.body(suppress(ctx.token, address("email", "a@example.com")), 201)
      sms = F.body(suppress(ctx.token, address("sms", "+905551112233")), 201)
      F.body(lift(ctx.token, sms["id"]), 200)

      all = F.body(F.request(:get, "/v1/suppressions", ctx.token), 200)
      assert Enum.map(all["data"], & &1["id"]) == [sms["id"], email["id"]]

      only = F.body(F.request(:get, "/v1/suppressions?channel=email", ctx.token), 200)
      assert Enum.map(only["data"], & &1["id"]) == [email["id"]]

      lifted = F.body(F.request(:get, "/v1/suppressions?state=lifted", ctx.token), 200)
      assert Enum.map(lifted["data"], & &1["id"]) == [sms["id"]]

      problem = F.body(F.request(:get, "/v1/suppressions?reason=bogus", ctx.token), 422)
      assert [%{"pointer" => "/reason"}] = problem["errors"]
    end

    test "PC-59: a tenant lifts manual and invalid suppressions with a reason, once", ctx do
      body = F.body(suppress(ctx.token, address("email", "a@example.com")), 201)
      lifted = F.body(lift(ctx.token, body["id"]), 200)

      assert %{"state" => "lifted", "lift_reason" => "the customer asked"} = lifted
      assert is_binary(lifted["lifted_at"])
      assert lifted["lifted_by"] == "cli_test"
      assert matches(ctx.scope, "a@example.com") == []

      again = F.body(lift(ctx.token, body["id"], "again"), 200)
      assert again["lift_reason"] == "the customer asked"
      assert [%{"target_type" => "suppression"}] = audit(ctx.scope, "suppression.lifted")

      unknown = Relay.ExternalId.encode("sup", Relay.Id.generate())
      assert code(lift(ctx.token, unknown), 404) == "suppression_not_found"
      assert code(lift(ctx.token, "sup_bad"), 404) == "suppression_not_found"
    end

    test "PC-59: a tenant cannot lift a hard bounce or a complaint", ctx do
      for reason <- ["hard_bounce", "complaint"] do
        id = bounced!(ctx.scope, reason <> "@example.com", reason)
        assert code(lift(ctx.token, id), 403) == "suppression_lift_forbidden"
        assert matches(ctx.scope, reason <> "@example.com") == [reason]
      end
    end

    test "API-79: listing needs read or subscribers and writing needs subscribers", ctx do
      reader = F.token(ctx.scope, ["read"])
      assert F.body(F.request(:get, "/v1/suppressions", reader), 200)["data"] == []
      body = %{"channel" => "email", "address" => "a@example.com"}
      assert code(suppress(reader, body), 403) == "auth_insufficient_scope"
    end
  end

  defp request(method, path, opts) do
    body = Keyword.get(opts, :body)
    raw = if body, do: Jason.encode!(body)
    content = if body, do: [{"content-type", "application/json"}], else: []

    cookies =
      opts
      |> Keyword.get(:cookies, %{})
      |> Map.merge(if opts[:as], do: %{@session => opts[:as].token}, else: %{})

    cookie = if cookies == %{}, do: [], else: [{"cookie", cookie_header(cookies)}]
    csrf = if opts[:as] && method != :get, do: [{"relay-csrf-token", opts[:as].csrf}], else: []
    key = if method != :get, do: [F.key()], else: []
    tenant = tenant_headers(opts[:tenant])

    method
    |> Api.conn(path, raw, content ++ cookie ++ csrf ++ key ++ tenant)
    |> Api.call(RelayWeb.Router)
  end

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
    login = request(:get, "/v1/operator/session/login?return_to=/panel", [])
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

  defp with_role(scope, role) do
    session = sign_in("op-" <> TenantFixture.random())

    {:ok, _row} =
      Admin.assign_role(
        scope,
        %{operator_id: session.operator_id, role: role, reason: "test"},
        TenantFixture.actor(),
        nil
      )

    session
  end

  defp operator_lift(scope, id, session) do
    path = "/v1/operator/suppressions/#{id}/lift"
    request(:post, path, body: %{"reason" => "provider confirmed"}, as: session, tenant: scope)
  end

  describe "PC-59 TN-22 operator lift" do
    test "TN-22, PC-59: a tenant administrator lifts a hard bounce only after a step-up", ctx do
      id = bounced!(ctx.scope, "bounced@example.com", "hard_bounce")

      operator = with_role(ctx.scope, :tenant_operator)
      assert json(operator_lift(ctx.scope, id, operator), 403)["code"] == "auth_insufficient_role"

      admin = with_role(ctx.scope, :tenant_admin)
      assert json(operator_lift(ctx.scope, id, admin), 401)["code"] == "auth_step_up_required"
      assert matches(ctx.scope, "bounced@example.com") == ["hard_bounce"]

      step_up(admin)
      lifted = json(operator_lift(ctx.scope, id, admin), 200)
      assert %{"state" => "lifted", "reason" => "hard_bounce"} = lifted
      assert lifted["lift_reason"] == "provider confirmed"
      assert lifted["lifted_by"] == admin.subject
      assert matches(ctx.scope, "bounced@example.com") == []

      unknown = Relay.ExternalId.encode("sup", Relay.Id.generate())
      missing = operator_lift(ctx.scope, unknown, admin)
      assert json(missing, 404)["code"] == "suppression_not_found"
    end
  end
end
