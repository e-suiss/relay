defmodule RelayWeb.Operator.ChannelOperationsApiTest do
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

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live}
  end

  defp secret_var(value) do
    var = "RELAY_TEST_OPERATOR_" <> String.upcase(random())
    System.put_env(var, value)
    on_exit(fn -> System.delete_env(var) end)
    "${" <> var <> "}"
  end

  defp admin(ctx), do: grant!(ctx.scope, sign_in("admin-" <> random()), :tenant_admin)

  defp installation_operator do
    session = sign_in("platform-" <> random())
    grant!(Operators.installation_scope(), session, :installation_operator)
  end

  defp tenant_account do
    %{
      "channel" => "sms",
      "provider" => "fake",
      "ownership" => "tenant",
      "credential_ref" => secret_var("token-" <> random()),
      "role" => "primary",
      "priority" => 0,
      "in_installation" => true,
      "transfer_basis" => "none"
    }
  end

  defp post(ctx, path, body, session),
    do: request(:post, path, body: body, as: session, tenant: ctx.scope)

  defp account_id(body), do: elem(Relay.ExternalId.decode(body["id"], ["pva"]), 1)

  defp credential_id(ctx, body) do
    {:ok, row} = Relay.Channels.get_managed(ctx.scope, :account, account_id(body))
    row["credential_ref_id"]
  end

  describe "TN-21 TN-26 provider accounts on the operator surface" do
    test "TN-21: adding an account needs a fresh step-up and keeps only the fingerprint", ctx do
      admin = admin(ctx)
      body = tenant_account()
      refused = json(post(ctx, "/v1/operator/provider_accounts", body, admin), 401)
      assert refused["code"] == "auth_step_up_required"

      step_up(admin)
      conn = post(ctx, "/v1/operator/provider_accounts", body, admin)
      created = json(conn, 201)
      assert %{"ownership" => "tenant", "verification_state" => "unverified"} = created
      assert created["credential"]["state"] == "active"
      refute conn.resp_body =~ "RELAY_TEST_OPERATOR_"
    end

    test "TN-26 (2): a credential that does not resolve is a field error", ctx do
      admin = step_up(admin(ctx))
      body = Map.put(tenant_account(), "credential_ref", "${RELAY_TEST_OPERATOR_MISSING_VAR}")
      problem = json(post(ctx, "/v1/operator/provider_accounts", body, admin), 422)
      assert [%{"pointer" => "/credential_ref"}] = problem["errors"]
    end

    test "TN-72: only the installation operator adds a shared account", ctx do
      body =
        tenant_account()
        |> Map.delete("credential_ref")
        |> Map.put("ownership", "shared")

      admin = step_up(admin(ctx))
      refused = json(post(ctx, "/v1/operator/provider_accounts", body, admin), 403)
      assert refused["code"] == "auth_insufficient_role"

      platform = ctx.scope |> grant!(installation_operator(), :tenant_admin) |> step_up()
      shared = json(post(ctx, "/v1/operator/provider_accounts", body, platform), 201)
      assert shared["credential"] == nil
    end

    test "TN-26 (5): a rotation points the account at a new reference and retires the old", ctx do
      admin = step_up(admin(ctx))
      created = json(post(ctx, "/v1/operator/provider_accounts", tenant_account(), admin), 201)
      old = credential_id(ctx, created)
      path = "/v1/operator/provider_accounts/" <> created["id"] <> "/rotate_credential"
      rotation = %{"credential_ref" => secret_var("token-" <> random())}

      rotated = json(post(ctx, path, rotation, admin), 200)
      assert rotated["credential"]["version"] == 2
      assert rotated["credential"]["fingerprint"] != created["credential"]["fingerprint"]
      refute credential_id(ctx, rotated) == old
      assert {:ok, %{state: :retired}} = Relay.Secrets.get(ctx.scope, old)
    end

    test "OP-73: archiving keeps the row, retires the credential and is idempotent", ctx do
      admin = step_up(admin(ctx))
      created = json(post(ctx, "/v1/operator/provider_accounts", tenant_account(), admin), 201)
      path = "/v1/operator/provider_accounts/" <> created["id"] <> "/archive"

      assert json(post(ctx, path, nil, admin), 200)["state"] == "archived"
      assert json(post(ctx, path, nil, admin), 200)["state"] == "archived"
      assert {:ok, %{state: :retired}} = Relay.Secrets.get(ctx.scope, credential_id(ctx, created))
    end
  end

  describe "C-25 TN-10 sender identities on the operator surface" do
    setup ctx do
      account = Relay.Id.generate()
      id = Relay.Id.generate()
      actor = TenantFixture.actor()

      attrs = %{
        id: account,
        channel: "sms",
        provider: "fake",
        ownership: "shared",
        role: "primary",
        priority: 0,
        in_installation: true,
        transfer_basis: "none"
      }

      {:ok, {:created, 1}} =
        Relay.Channels.put_account(ctx.scope, attrs, TenantFixture.digest(), actor)

      sender = %{
        id: id,
        provider_account_id: account,
        channel: "sms",
        kind: "sms_sender",
        value: "RELAY",
        approval_state: "pending"
      }

      {:ok, {:created, 1}} =
        Relay.Channels.put_sender_identity(ctx.scope, sender, TenantFixture.digest(), actor)

      %{path: "/v1/operator/sender_identities/" <> Relay.ExternalId.encode("snd", id)}
    end

    test "C-25: a tenant administrator approves a sender identity", ctx do
      body = %{"approval_state" => "approved"}
      reviewed = json(post(ctx, ctx.path <> "/review", body, admin(ctx)), 200)
      assert reviewed["approval_state"] == "approved"
    end

    test "TN-10, TN-21: the installation operator suspends and resumes with step-up", ctx do
      body = %{"rule_id" => "channel.sender_unapproved"}
      admin = step_up(admin(ctx))
      refused = json(post(ctx, ctx.path <> "/suspend", body, admin), 403)
      assert refused["code"] == "auth_insufficient_role"

      platform = step_up(installation_operator())
      suspended = json(post(ctx, ctx.path <> "/suspend", body, platform), 200)
      assert suspended["suspension_rule_id"] == "channel.sender_unapproved"
      assert json(post(ctx, ctx.path <> "/resume", %{}, platform), 200)["suspended_at"] == nil
    end
  end

  describe "C-26 TN-26 channel identities on the operator surface" do
    test "TN-26 (5): a channel identity is added and its key rotated", ctx do
      admin = step_up(admin(ctx))

      body = %{
        "channel" => "slack",
        "kind" => "slack_app",
        "app_ref" => "A" <> random(),
        "secret_ref" => secret_var("xoxb-" <> random())
      }

      created = json(post(ctx, "/v1/operator/channel_identities", body, admin), 201)
      assert created["secret"]["version"] == 1
      again = json(post(ctx, "/v1/operator/channel_identities", body, admin), 409)
      assert again["code"] == "resource_conflict"

      path = "/v1/operator/channel_identities/" <> created["id"] <> "/rotate_secret"
      rotation = %{"secret_ref" => secret_var("xoxb-" <> random())}
      assert json(post(ctx, path, rotation, admin), 200)["secret"]["version"] == 2
    end
  end
end
