defmodule RelayWeb.Api.IysApiTest do
  use Relay.DataCase, async: false

  alias Relay.Iys.TokenCache
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.IysFake, as: Fake
  alias RelayTest.TenantFixture

  @brand 9001

  setup do
    start_supervised!({Fake, []})
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.live
    %{tenant: tenant, scope: scope, token: F.token(scope), credential: credential!(scope)}
  end

  defp credential!(scope) do
    var = "RELAY_TEST_IYS_API_" <> String.upcase(TenantFixture.random())
    System.put_env(var, "iys-password")
    on_exit(fn -> System.delete_env(var) end)
    digest = TenantFixture.digest()
    actor = TenantFixture.actor()
    {:ok, ref} = Relay.Secrets.register_ref(scope, :iys_credential, "${#{var}}", 1, digest, actor)
    Relay.ExternalId.encode("sec", ref.id)
  end

  defp body(ctx, changes \\ %{}) do
    Map.merge(
      %{
        "mode" => "own",
        "api" => "sandbox",
        "iys_code" => 600_001,
        "username" => "iys-user",
        "credential_ref_id" => ctx.credential,
        "brands" => [%{"brand_code" => @brand, "name" => "Marka"}]
      },
      changes
    )
  end

  defp put(ctx, body), do: F.request(:put, "/v1/iys/config", ctx.token, body)
  defp get(ctx, path), do: F.request(:get, path, ctx.token)

  describe "PC-29 the İYS configuration" do
    test "PC-29: the configuration is entered, read back and never shows the password", ctx do
      assert F.body(get(ctx, "/v1/iys/config"), 404)["code"] == "iys_not_configured"

      conn = put(ctx, body(ctx))
      created = F.body(conn, 200)

      assert %{"object" => "iys_config", "mode" => "own", "api" => "sandbox", "version" => 1} =
               created

      assert created["credential_ref_id"] == ctx.credential

      assert created["quota"] == %{
               "state" => "unknown",
               "consent_limit" => nil,
               "used_consent_limit" => nil,
               "checked_at" => nil
             }

      assert [%{"brand_code" => @brand, "subtenant_id" => nil} = brand] = created["brands"]
      assert brand["access"] == %{"sms" => "write", "voice" => "write", "email" => "write"}
      refute conn.resp_body =~ "iys-password"
      refute conn.resp_body =~ "RELAY_TEST_IYS_API_"

      assert F.body(get(ctx, "/v1/iys/config"), 200)["version"] == 1

      listed = F.body(get(ctx, "/v1/iys/brands"), 200)

      assert %{"object" => "list", "has_more" => false, "data" => [%{"brand_code" => @brand}]} =
               listed
    end

    test "PC-29, E-22: the two modes are entered alike and an integrator's access starts unknown",
         ctx do
      integrator = body(ctx, %{"mode" => "integrator", "integrator_code" => 700_001})
      created = F.body(put(ctx, integrator), 200)

      assert %{"mode" => "integrator", "integrator_code" => 700_001} = created
      assert [%{"access" => %{"sms" => "unknown"}, "authorised_at" => nil}] = created["brands"]

      missing = F.body(put(ctx, body(ctx, %{"mode" => "integrator"})), 422)
      assert [%{"pointer" => "/integrator_code", "code" => "required"}] = missing["errors"]

      extra = F.body(put(ctx, body(ctx, %{"integrator_code" => 700_001})), 422)
      assert [%{"pointer" => "/integrator_code", "code" => "not_allowed"}] = extra["errors"]
    end

    test "PC-29: an unknown credential, a repeated brand and a stale version are refused", ctx do
      stranger = Relay.ExternalId.encode("sec", Relay.Id.generate())
      unknown = F.body(put(ctx, body(ctx, %{"credential_ref_id" => stranger})), 422)
      assert [%{"pointer" => "/credential_ref_id", "code" => "not_found"}] = unknown["errors"]

      twice = [%{"brand_code" => @brand}, %{"brand_code" => @brand}]
      repeated = F.body(put(ctx, body(ctx, %{"brands" => twice})), 422)
      assert [%{"pointer" => "/brands", "code" => "conflict"}] = repeated["errors"]

      F.body(put(ctx, body(ctx, %{"expected_version" => 0})), 200)
      stale = F.body(put(ctx, body(ctx, %{"expected_version" => 0})), 409)
      assert stale["code"] == "resource_conflict"
      assert F.body(put(ctx, body(ctx, %{"expected_version" => 1})), 200)["version"] == 2
    end
  end

  describe "PC-34 PC-30 the connection and its uploads" do
    test "PC-29, PC-34: the connection test reports what İYS answered and writes nothing", ctx do
      assert F.body(get(ctx, "/v1/iys/connection_test"), 404)["code"] == "iys_not_configured"

      brands = [%{"brand_code" => @brand}, %{"brand_code" => 4242}]
      F.body(put(ctx, body(ctx, %{"brands" => brands})), 200)
      report = F.body(get(ctx, "/v1/iys/connection_test"), 200)

      assert %{"object" => "iys_connection_test", "token" => "ok"} = report
      assert report["brands"] == %{"result" => "ok", "found" => [@brand], "missing" => [4242]}

      assert %{"result" => "ok", "status" => "ACTIVE", "consent_limit" => 1000} =
               report["subscription"]

      assert Fake.consents() == %{}

      :ok = Fake.put(:password, "changed")
      :ok = TokenCache.drop(TokenCache, cache_key(ctx))
      assert F.body(get(ctx, "/v1/iys/connection_test"), 200)["token"] == "H251"
    end

    test "PC-30: the upload list is the operator's queue and never shows an address", ctx do
      F.body(put(ctx, body(ctx)), 200)
      refusal = %{channel: "email", address: "ayse@example.com", source: "one_click", brand: 77}
      assert {:ok, :brand_not_mapped} = Relay.Iys.write_refusal(ctx.scope, refusal)
      assert {:ok, :queued} = Relay.Iys.write_refusal(ctx.scope, %{refusal | brand: @brand})

      conn = get(ctx, "/v1/iys/uploads?state=failed")
      assert %{"data" => [failed], "has_more" => false} = F.body(conn, 200)

      assert %{"object" => "iys_upload", "state" => "failed", "status" => "rejection"} = failed

      assert %{"channel" => "email", "error_code" => "brand_not_mapped", "origin" => "refusal"} =
               failed

      assert failed["id"] =~ ~r/^iyu_/
      refute conn.resp_body =~ "ayse@example.com"

      assert %{"data" => [_pending, _failed]} = F.body(get(ctx, "/v1/iys/uploads"), 200)
      assert get(ctx, "/v1/iys/uploads?state=lost").status == 422
    end
  end

  defp cache_key(ctx) do
    {:ok, %{config: config}} = Relay.Iys.get_config(ctx.scope)
    {ctx.scope.tenant_id, ctx.scope.environment, config["id"], config["version"]}
  end
end
