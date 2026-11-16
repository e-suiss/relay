defmodule RelayWeb.Operator.ApiClientAssignmentApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Access.ClientStore
  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"

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
    key = if method != :get, do: [{"idempotency-key", "key-" <> random()}], else: []

    method
    |> Api.conn(path, raw, content ++ cookie ++ csrf ++ key ++ tenant_headers(opts[:tenant]))
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

  defp admin(scopes) do
    session = sign_in("admin-" <> random())

    for scope <- scopes do
      {:ok, _row} =
        Admin.assign_role(
          scope,
          %{operator_id: session.operator_id, role: :tenant_admin, reason: "test"},
          TenantFixture.actor(),
          nil
        )
    end

    session
  end

  defp register!(tenant, client) do
    {:ok, actor} = Relay.Actor.new(:access, "access", "access")
    id = Relay.Id.generate()
    digest = TenantFixture.digest()
    work = fn _status -> ClientStore.register(id, client, "evt_test", digest, actor) end
    assert {:ok, {:created, ^id}} = ClientStore.in_scope(tenant.live, work)
  end

  setup do
    %{tenant: TenantFixture.tenant!()}
  end

  @list "/v1/operator/pending_api_clients"
  @assign "/v1/operator/pending_api_clients/assign"

  defp pending(session, scope), do: request(:get, @list, as: session, tenant: scope)

  defp grant(session, scope, body),
    do: request(:post, @assign, body: body, as: session, tenant: scope)

  describe "E-99 pending API clients on the operator surface" do
    test "E-99, TN-21: a tenant administrator with step-up assigns a pending client", ctx do
      %{tenant: tenant} = ctx
      register!(tenant, "app_operator")
      session = admin([tenant.live, tenant.test])

      listed = json(pending(session, tenant.test), 200)

      assert [%{"object" => "pending_api_client", "access_client_id" => "app_operator"}] =
               listed["data"]

      body = %{"access_client_id" => "app_operator", "scopes" => ["publish", "read"]}
      assert json(grant(session, tenant.test, body), 401)["code"] == "auth_step_up_required"

      step_up(session)
      assigned = json(grant(session, tenant.test, body), 200)
      assert %{"object" => "api_client", "environment" => "test", "status" => "active"} = assigned
      assert assigned["scopes"] == ["publish", "read"]
      assert json(grant(session, tenant.test, body), 200)["id"] == assigned["id"]
      assert json(grant(session, tenant.live, body), 409)["code"] == "resource_conflict"
      assert json(pending(session, tenant.live), 200)["data"] == []
    end

    test "E-99: an unknown client and scopes outside API-75 are refused", ctx do
      %{tenant: tenant} = ctx
      session = step_up(admin([tenant.live]))

      missing = %{"access_client_id" => "app_missing", "scopes" => ["read"]}
      assert json(grant(session, tenant.live, missing), 404)["code"] == "api_client_not_found"

      wrong = %{"access_client_id" => "app_missing", "scopes" => ["admin"]}
      assert json(grant(session, tenant.live, wrong), 422)["code"] == "validation_failed"
    end
  end
end
