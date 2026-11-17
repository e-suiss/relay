defmodule RelayWeb.Operator.TenantSettingsApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

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

  defp settings(session, scope, body),
    do: request(:put, "/v1/operator/settings", body: body, as: session, tenant: scope)

  defp version(scope) do
    {:ok, tenant} = Relay.Tenancy.tenant(scope)
    tenant["version"]
  end

  describe "TN-2 OP-19 tenant settings changes" do
    setup do
      :ok = TenantFixture.retention_periods!()
      tenant = TenantFixture.tenant!()
      admin = sign_in("admin-" <> random()) |> then(&grant!(tenant.live, &1, :tenant_admin))
      %{scope: tenant.live, admin: admin}
    end

    test "TN-2: the tenant admin changes the default time zone and locale under the version",
         %{scope: scope, admin: admin} do
      body = %{
        "version" => version(scope),
        "default_timezone" => "Europe/Berlin",
        "default_locale" => "de-DE"
      }

      changed = json(settings(admin, scope, body), 200)
      assert changed["object"] == "tenant_settings"
      assert changed["default_timezone"] == "Europe/Berlin"
      assert changed["default_locale"] == "de-DE"
      assert changed["version"] > body["version"]

      assert json(settings(admin, scope, body), 409)["code"] == "resource_conflict"

      invalid = %{"version" => changed["version"], "default_timezone" => "Mars/Olympus"}
      problem = json(settings(admin, scope, invalid), 422)
      assert [%{"pointer" => "/default_timezone"}] = problem["errors"]
    end

    test "OP-19, TN-21: a retention period needs step-up and may only extend the legal one",
         %{scope: scope, admin: admin} do
      {:ok, periods} = Relay.Tenancy.retention_periods(scope)
      legal = Enum.find(periods, &(&1.class == "commercial_message")).legal_days
      assert is_integer(legal)

      longer = %{
        "version" => version(scope),
        "retention" => %{"commercial_message" => legal + 365}
      }

      assert json(settings(admin, scope, longer), 401)["code"] == "auth_step_up_required"

      step_up(admin)
      body = json(settings(admin, scope, longer), 200)
      period = Enum.find(body["retention"], &(&1["retention_class"] == "commercial_message"))
      assert period["days"] == legal + 365
      assert period["effective_days"] == legal + 365

      shorter = %{longer | "retention" => %{"commercial_message" => legal - 1}}
      problem = json(settings(admin, scope, shorter), 422)

      assert [%{"pointer" => "/retention/commercial_message", "code" => "not_allowed"}] =
               problem["errors"]
    end

    test "TN-2: a tenant operator cannot change the settings", %{scope: scope} do
      operator = sign_in("operator-" <> random()) |> then(&grant!(scope, &1, :tenant_operator))
      body = %{"version" => version(scope), "default_locale" => "en-GB"}

      assert json(settings(operator, scope, body), 403)["code"] == "auth_insufficient_role"
    end
  end
end
