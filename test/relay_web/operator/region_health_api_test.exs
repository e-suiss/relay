defmodule RelayWeb.Operator.RegionHealthApiTest do
  use Relay.DataCase, async: true

  import Plug.Conn

  alias Relay.Operators
  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"

  defp request(method, path, opts) do
    cookies = Keyword.get(opts, :cookies, %{})
    cookies = if opts[:as], do: Map.put(cookies, @session, opts[:as].token), else: cookies
    cookie = if cookies == %{}, do: [], else: [{"cookie", cookie_header(cookies)}]

    method
    |> Api.conn(path, nil, cookie)
    |> Api.call(RelayWeb.Router)
  end

  defp cookie_header(cookies), do: Enum.map_join(cookies, "; ", fn {k, v} -> k <> "=" <> v end)

  defp json(conn, status) do
    assert conn.status == status, conn.resp_body
    Api.assert_contract(conn)
    Jason.decode!(conn.resp_body)
  end

  defp sign_in(subject) do
    login = request(:get, "/v1/operator/session/login?return_to=/panel", [])
    assert login.status == 302
    [location] = get_resp_header(login, "location")
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    state = query["state"]
    flow = login.resp_cookies["relay_operator_login"].value

    code =
      FakeAccess.issue("code", %{"sub" => subject, "sid" => "sid-" <> subject, "auth_time" => 0})

    callback =
      request(
        :get,
        "/v1/operator/session/callback?" <> URI.encode_query(%{"code" => code, "state" => state}),
        cookies: %{"relay_operator_login" => flow}
      )

    assert callback.status == 302
    token = callback.resp_cookies[@session].value
    show = json(request(:get, "/v1/operator/session", cookies: %{@session => token}), 200)
    {:ok, operator_id} = Relay.ExternalId.decode(show["operator"]["id"], ["opr"])
    %{token: token, operator_id: operator_id}
  end

  defp grant!(session, scope, role) do
    {:ok, _row} =
      Admin.assign_role(
        scope,
        %{operator_id: session.operator_id, role: role, reason: "test"},
        TenantFixture.actor(),
        nil
      )

    session
  end

  defp subject, do: "region-" <> TenantFixture.random()

  describe "X-7 region health" do
    test "X-7: the installation operator sees each check of this region" do
      installation = Operators.installation_scope()
      operator = grant!(sign_in(subject()), installation, :installation_operator)
      body = json(request(:get, "/v1/operator/region_health", as: operator), 200)

      assert body["region"] == Relay.Datasets.installation_region()
      assert body["queue_panel_url"] == "/v1/operator/queues"

      names = Enum.map(body["checks"], & &1["name"])
      assert names == ~w(database key_store valkey kill_switch_state channel_parameters)

      ok? = Enum.all?(body["checks"], &(&1["status"] == "ok"))
      assert body["status"] == if(ok?, do: "ok", else: "degraded")
      assert %{"status" => "ok", "reason" => nil} = hd(body["checks"])
    end

    test "X-7: a tenant role does not see the region health" do
      tenant = TenantFixture.tenant!()
      admin = grant!(sign_in(subject()), tenant.live, :tenant_admin)
      body = json(request(:get, "/v1/operator/region_health", as: admin), 403)
      assert body["code"] == "auth_insufficient_role"
    end
  end
end
