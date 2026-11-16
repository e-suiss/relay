defmodule RelayWeb.Operator.WebhookEndpointApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture
  alias RelayTest.WebhookEngine, as: Fake

  @session "relay_operator_session"
  @url "https://siem.example.com/relay"
  @type_name "audit_record.appended"

  setup do
    previous = Fake.install()
    on_exit(fn -> Application.put_env(:relay, Relay.Webhooks, previous) end)
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
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

  defp endpoint!(ctx, body) do
    body = Map.merge(%{"destination" => %{"kind" => "https", "url" => @url}}, body)
    F.body(F.request(:post, "/v1/webhook_endpoints", ctx.token, body), 201)
  end

  defp subscribe(scope, endpoint_id, session, type \\ @type_name) do
    path = "/v1/operator/webhook_endpoints/#{endpoint_id}/subscribe"
    request(:post, path, body: %{"event_type" => type}, as: session, tenant: scope)
  end

  describe "WH-67 TN-50 choosing the audit records of a tenant for an endpoint" do
    test "WH-67, TN-50: only a tenant administrator, who may read the audit log, subscribes an endpoint to audit_record.appended",
         ctx do
      endpoint = endpoint!(ctx, %{"use" => "relay_events", "event_types" => ["*"]})
      id = endpoint["id"]

      operator = with_role(ctx.scope, :tenant_operator)
      assert json(subscribe(ctx.scope, id, operator), 403)["code"] == "auth_insufficient_role"

      admin = with_role(ctx.scope, :tenant_admin)
      subscribed = json(subscribe(ctx.scope, id, admin), 200)
      assert %{"object" => "webhook_endpoint", "id" => ^id} = subscribed
      assert subscribed["event_types"] == ["*", @type_name]

      again = json(subscribe(ctx.scope, id, admin), 200)
      assert again["event_types"] == ["*", @type_name]
      assert again["version"] == subscribed["version"]

      read = F.body(F.request(:get, "/v1/webhook_endpoints/" <> id, ctx.token), 200)
      assert read["event_types"] == ["*", @type_name]
    end

    test "WH-67: a type that * covers, an endpoint of use destination and an unknown endpoint are refused",
         ctx do
      admin = with_role(ctx.scope, :tenant_admin)
      endpoint = endpoint!(ctx, %{"use" => "relay_events", "event_types" => []})

      covered = json(subscribe(ctx.scope, endpoint["id"], admin, "notification.delivered"), 422)
      assert covered["code"] == "validation_failed"
      assert Enum.any?(covered["errors"], &(&1["pointer"] == "/event_type"))

      key = "shop-" <> TenantFixture.random()
      F.body(F.request(:post, "/v1/webhook_consumers", ctx.token, %{"key" => key}), 201)
      body = %{"use" => "destination", "consumer" => key, "event_types" => []}
      destination = endpoint!(ctx, body)
      refused = json(subscribe(ctx.scope, destination["id"], admin), 422)
      assert refused["code"] == "validation_failed"

      missing = Relay.ExternalId.encode("whe", Relay.Id.generate())
      unknown = json(subscribe(ctx.scope, missing, admin), 404)
      assert unknown["code"] == "webhook_endpoint_not_found"
    end
  end
end
