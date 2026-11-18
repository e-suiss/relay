defmodule RelayWeb.Api.TestPlaneConsoleTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"

  setup do
    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.test}
  end

  defp request(method, path, opts) do
    cookies = Keyword.get(opts, :cookies, %{})
    cookies = if opts[:as], do: Map.put(cookies, @session, opts[:as].token), else: cookies

    cookie =
      if cookies == %{},
        do: [],
        else: [{"cookie", Enum.map_join(cookies, "; ", fn {k, v} -> k <> "=" <> v end)}]

    csrf = if opts[:as] && method != :get, do: [{"relay-csrf-token", opts[:as].csrf}], else: []
    key = if method != :get, do: [{"idempotency-key", "key-" <> TenantFixture.random()}], else: []

    method
    |> Api.conn(path, nil, cookie ++ csrf ++ key ++ tenant(opts[:tenant]))
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
    Jason.decode!(conn.resp_body)
  end

  defp query(location), do: location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp operator(scope) do
    subject = "console-" <> TenantFixture.random()
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

    {:ok, _row} =
      Admin.assign_role(
        scope,
        %{operator_id: operator_id, role: :tenant_operator, reason: "test"},
        TenantFixture.actor(),
        nil
      )

    %{token: token, csrf: show["csrf_token"]}
  end

  describe "X-47 X-52 X-43 console on the test plane" do
    test "X-47: the console reads the test inbox and the seeds and resets them with its session",
         ctx do
      session = operator(ctx.scope)

      inbox = json(request(:get, "/v1/test/inbox", as: session, tenant: ctx.scope), 200)
      assert inbox["object"] == "list"

      seeds = request(:get, "/v1/test/seed-recipients", as: session, tenant: ctx.scope)
      assert length(json(seeds, 200)["data"]) == 7

      reset = request(:post, "/v1/test/seed-recipients/reset", as: session, tenant: ctx.scope)
      assert json(reset, 202)["status"] == "queued"
    end

    test "X-47: the session without the tenant context is refused", ctx do
      session = operator(ctx.scope)
      assert request(:get, "/v1/test/inbox", as: session).status == 422
    end
  end
end
