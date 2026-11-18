defmodule RelayWeb.Operator.TenantLifecycleApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

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
        "acr" => "http://idmanagement.gov/ns/assurance/aal/2",
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

  setup do
    TenantFixture.retention_periods!()
    tenant = TenantFixture.tenant!()
    Req.Test.stub(Relay.TenantLifecycle.ExportStore.S3, &Plug.Conn.send_resp(&1, 200, ""))
    %{tenant: tenant, path: "/v1/operator/tenants/" <> Relay.ExternalId.encode("ten", tenant.id)}
  end

  describe "OP-85 OP-86 operator surface" do
    test "OP-85: the installation operator sets a tenant's own key with step-up", ctx do
      platform = installation_operator()
      ref = "pkcs11:token=relay-test;object=tenant-" <> random()

      stale = request(:put, ctx.path <> "/key_custody", body: %{"key_ref" => ref}, as: platform)
      assert json(stale, 401)["code"] == "auth_step_up_required"

      platform = step_up(platform)
      put = request(:put, ctx.path <> "/key_custody", body: %{"key_ref" => ref}, as: platform)

      assert %{"object" => "tenant_key_custody", "key_ref" => ^ref, "keys_under_other" => 0} =
               json(put, 200)

      shown = json(request(:get, ctx.path <> "/key_custody", as: platform), 200)
      assert shown["keys_under_key"] == 4

      bad = %{"key_ref" => "pkcs11:object=no-token"}
      refused = json(request(:put, ctx.path <> "/key_custody", body: bad, as: platform), 422)
      assert refused["code"] == "validation_failed"
    end

    test "OP-86: the closure is requested, read and guarded through the operator API", ctx do
      platform = step_up(installation_operator())

      missing = json(request(:get, ctx.path <> "/closure", as: platform), 404)
      assert missing["code"] == "tenant_closure_not_found"

      body = %{"reason" => "contract ended", "formats" => ["jsonl"]}
      created = json(request(:post, ctx.path <> "/closure", body: body, as: platform), 201)

      assert %{"object" => "tenant_closure", "state" => "exporting", "files" => []} = created
      assert created["formats"] == ["jsonl"]

      shown = json(request(:get, ctx.path <> "/closure", as: platform), 200)
      assert shown["state"] == "exporting"

      confirm = %{"confirmation_ref" => "access-record-1"}
      early = request(:post, ctx.path <> "/closure/confirm", body: confirm, as: platform)
      assert json(early, 409)["code"] == "resource_conflict"

      shred = request(:post, ctx.path <> "/closure/shred", as: platform)
      assert json(shred, 409)["code"] == "resource_conflict"

      again = json(request(:post, ctx.path <> "/closure", body: body, as: platform), 409)
      assert again["code"] == "resource_conflict"
    end

    test "OP-86: an unknown tenant is not found", _ctx do
      platform = step_up(installation_operator())
      path = "/v1/operator/tenants/" <> Relay.ExternalId.encode("ten", Relay.Id.generate())
      missing = json(request(:get, path <> "/closure", as: platform), 404)
      assert missing["code"] == "tenant_not_found"
    end
  end
end
