defmodule RelayWeb.Operator.IysOperationsApiTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias Relay.Datasets
  alias Relay.Operators.Admin
  alias RelayTest.Api
  alias RelayTest.IysFake, as: Fake
  alias RelayTest.Operators.Access, as: FakeAccess
  alias RelayTest.TenantFixture

  @session "relay_operator_session"
  @brand 9001
  @phone "+905321112233"

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
    key = if method != :get, do: [{"idempotency-key", opts[:key] || "key-" <> random()}], else: []
    tenant = tenant_headers(opts[:tenant])

    method
    |> Api.conn(path, raw, content ++ cookie ++ csrf ++ key ++ tenant)
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

  defp operator(scope, role) do
    session = sign_in("op-" <> random())

    {:ok, _row} =
      Admin.assign_role(
        scope,
        %{operator_id: session.operator_id, role: role, reason: "test"},
        TenantFixture.actor(),
        nil
      )

    session
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

    for row <- rows, do: {row["target_type"], row["target_id"], row["reason"]}
  end

  defp credential!(scope) do
    var = "RELAY_TEST_IYS_" <> String.upcase(TenantFixture.random())
    System.put_env(var, "iys-password")
    on_exit(fn -> System.delete_env(var) end)
    digest = TenantFixture.digest()
    actor = TenantFixture.actor()
    {:ok, ref} = Relay.Secrets.register_ref(scope, :iys_credential, "${#{var}}", 1, digest, actor)
    ref.id
  end

  defp configure!(scope) do
    config = %{
      "mode" => "own",
      "api" => "sandbox",
      "iys_code" => 600_001,
      "integrator_code" => nil,
      "username" => "iys-user",
      "credential_ref_id" => Relay.Id.to_string(credential!(scope))
    }

    brands = [%{"brand_code" => @brand, "name" => "Marka", "subtenant_id" => nil}]

    {:ok, {:created, 1}} =
      Relay.Iys.in_scope(scope, fn _status ->
        Relay.Iys.put_config(config, brands, nil, TenantFixture.digest(), TenantFixture.actor())
      end)

    :ok
  end

  defp upload!(scope) do
    movement = %{
      channel: "sms",
      status: :approval,
      address: @phone,
      source: "web",
      occurred_at: DateTime.add(DateTime.utc_now(), -30, :second),
      origin: :access,
      recipient_type: "individual",
      recipient_id: nil,
      brand_subtenant_id: nil
    }

    assert {:ok, :queued} = Relay.Iys.write(scope, movement)
    {:ok, [upload | _older]} = Relay.Iys.list_uploads(scope, nil, nil, 50)
    upload
  end

  defp retry(scope, id, session) do
    path = "/v1/operator/iys/uploads/" <> id <> "/retry"
    request(:post, path, body: %{"reason" => "brand fixed at İYS"}, as: session, tenant: scope)
  end

  setup do
    calendar = {Datasets.installation_scope(), "business_calendar"}
    Datasets.Cache.invalidate(Datasets.Cache, calendar)
    on_exit(fn -> Datasets.Cache.invalidate(Datasets.Cache, calendar) end)
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    start_supervised!({Fake, []})

    tenant = TenantFixture.tenant!()
    %{tenant: tenant, scope: tenant.live}
  end

  describe "PC-32 OP-42 the synchronisation state on the operator surface" do
    test "PC-32, PC-33: the operator reads the last pull, the blind spot and the drift of every brand",
         ctx do
      session = operator(ctx.scope, :tenant_operator)
      path = "/v1/operator/iys/sync"

      missing = json(request(:get, path, as: session, tenant: ctx.scope), 404)
      assert missing["code"] == "iys_not_configured"

      configure!(ctx.scope)
      never = json(request(:get, path, as: session, tenant: ctx.scope), 200)
      assert %{"object" => "iys_sync", "blind_spot_seconds" => 3_600, "brands" => [brand]} = never
      assert %{"brand_code" => @brand, "last_pull_at" => nil, "cursor_age_seconds" => nil} = brand
      assert %{"drift_count" => 0, "address_state" => "ok", "stale_state" => "fresh"} = brand

      assert {:ok, [%{pull: :ok}]} = Relay.Iys.sync(ctx.scope, DateTime.utc_now())
      synced = json(request(:get, path, as: session, tenant: ctx.scope), 200)
      assert [brand] = synced["brands"]
      assert %{"object" => "iys_brand_sync", "last_error_code" => nil} = brand
      assert is_binary(brand["last_pull_at"])
      assert is_binary(brand["covered_until"])
      assert is_binary(brand["reconciled_at"])
      assert brand["cursor_age_seconds"] >= 0
      refute brand["full_sync_running"]

      refused = json(request(:get, path, tenant: ctx.scope), 401)
      assert refused["code"] == "auth_missing_credentials"
    end
  end

  describe "PC-34 retry of a failed upload" do
    test "PC-34, TN-47: the operator opens a failed upload again and the retry is audited", ctx do
      configure!(ctx.scope)
      upload = upload!(ctx.scope)
      id = Relay.ExternalId.encode("iyu", upload["id"])
      session = operator(ctx.scope, :tenant_operator)

      conflict = json(retry(ctx.scope, id, session), 409)
      assert conflict["code"] == "resource_conflict"

      :ok = Fake.fail_next(:add, 400, "H178")
      assert Relay.Iys.run_upload(ctx.scope, upload["id"]) == :done
      assert {:ok, [%{"state" => "failed"}]} = Relay.Iys.list_uploads(ctx.scope, "failed", nil, 5)

      retried = json(retry(ctx.scope, id, session), 200)
      assert %{"object" => "iys_upload", "id" => ^id, "state" => "pending"} = retried
      assert %{"attempts" => 0, "settled_at" => nil, "error_code" => "H178"} = retried

      assert audit(ctx.scope, "iys_upload.retried") ==
               [{"iys_upload", Relay.Id.to_string(upload["id"]), "brand fixed at İYS"}]

      assert Relay.Iys.run_upload(ctx.scope, upload["id"]) == :done

      assert {:ok, [%{"state" => "confirmed"}]} =
               Relay.Iys.list_uploads(ctx.scope, "confirmed", nil, 5)

      again = json(retry(ctx.scope, id, session), 409)
      assert again["code"] == "resource_conflict"
      assert length(audit(ctx.scope, "iys_upload.retried")) == 1
    end

    test "PC-34: an unknown upload is not found and the retry needs a tenant operator", ctx do
      configure!(ctx.scope)
      session = operator(ctx.scope, :tenant_operator)
      unknown = Relay.ExternalId.encode("iyu", Relay.Id.generate())

      missing = json(retry(ctx.scope, unknown, session), 404)
      assert missing["code"] == "iys_upload_not_found"

      malformed = json(retry(ctx.scope, "iyu_nope", session), 404)
      assert malformed["code"] == "iys_upload_not_found"

      stranger = sign_in("stranger-" <> random())
      refused = json(retry(ctx.scope, unknown, stranger), 403)
      assert refused["code"] == "auth_insufficient_role"
    end
  end
end
