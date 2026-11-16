defmodule RelayWeb.Operator.EmailReputationApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Datasets
  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"

  defp forget do
    Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), "email_reputation"})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)
    %{scope: TenantFixture.tenant!().live}
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

  defp close(scope, domain, session) do
    path = "/v1/operator/email_reputation/#{domain}/close"
    request(:post, path, body: %{"reason" => "list cleaned"}, as: session, tenant: scope)
  end

  describe "CH-87 TN-22 closing a stopped circuit" do
    test "CH-87: a tenant administrator closes a stopped circuit only after a step-up", ctx do
      domain = "news.example.com"
      {:ok, :ok} = Relay.EmailReputation.count(ctx.scope, domain, :sent, 500)
      {:ok, :stopped} = Relay.EmailReputation.count(ctx.scope, domain, :bounce, 40)

      operator = with_role(ctx.scope, :tenant_operator)
      list = request(:get, "/v1/operator/email_reputation", as: operator, tenant: ctx.scope)
      assert [%{"domain" => ^domain, "state" => "stopped"}] = json(list, 200)["data"]
      assert json(close(ctx.scope, domain, operator), 403)["code"] == "auth_insufficient_role"

      admin = with_role(ctx.scope, :tenant_admin)
      assert json(close(ctx.scope, domain, admin), 401)["code"] == "auth_step_up_required"
      assert Relay.EmailReputation.admit(ctx.scope, domain) == :paused

      step_up(admin)
      assert %{"state" => "ok", "domain" => ^domain} = json(close(ctx.scope, domain, admin), 200)
      assert Relay.EmailReputation.admit(ctx.scope, domain) == :allow

      again = json(close(ctx.scope, domain, admin), 409)
      assert again["code"] == "resource_conflict"

      missing = json(close(ctx.scope, "other.example.com", admin), 404)
      assert missing["code"] == "email_reputation_not_found"
    end
  end
end
