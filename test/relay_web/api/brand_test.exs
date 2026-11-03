defmodule RelayWeb.Api.BrandTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @merge [{"content-type", "application/merge-patch+json"}]

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp patch(token, path, body, headers \\ []),
    do: F.request(:patch, path, token, body, @merge ++ headers)

  defp field(brand, name), do: brand["fields"][name]

  describe "TP-35 TP-36 brand fields" do
    test "TP-35: the tenant level starts empty and a merge patch sets and clears fields", ctx do
      conn = F.request(:get, "/v1/brand", ctx.token)
      empty = F.body(conn, 200)

      assert %{"object" => "brand", "subtenant" => nil} = empty
      assert field(empty, "logo_url") == %{"value" => nil, "source" => "none"}
      assert get_resp_header(conn, "etag") == [~s("1")]

      body = %{"logo_url" => "https://example.com/logo.png", "sender_name" => "Örnek"}
      set = patch(ctx.token, "/v1/brand", body)
      brand = F.body(set, 200)

      assert field(brand, "logo_url") == %{"value" => body["logo_url"], "source" => "tenant"}
      assert field(brand, "sender_name")["value"] == "Örnek"
      assert get_resp_header(set, "etag") == [~s("3")]

      stale = patch(ctx.token, "/v1/brand", %{"footer" => "x"}, [{"if-match", ~s("1")}])
      assert code(stale, 412) == "precondition_failed"

      cleared = patch(ctx.token, "/v1/brand", %{"logo_url" => nil}, [{"if-match", ~s("3")}])
      cleared = F.body(cleared, 200)
      assert field(cleared, "logo_url") == %{"value" => nil, "source" => "none"}
    end

    test "TP-36: a subtenant inherits every field it does not set", ctx do
      F.body(patch(ctx.token, "/v1/brand", %{"logo_url" => "https://example.com/a.png"}), 200)
      id = TenantFixture.subtenant!(ctx.scope)
      path = "/v1/brand?subtenant=" <> Relay.ExternalId.encode("stn", id)

      inherited = F.body(F.request(:get, path, ctx.token), 200)
      assert field(inherited, "logo_url")["source"] == "tenant"

      own = F.body(patch(ctx.token, path, %{"sender_name" => "Şube"}), 200)
      assert field(own, "sender_name") == %{"value" => "Şube", "source" => "subtenant"}
      assert field(own, "logo_url")["source"] == "tenant"

      tenant = F.body(F.request(:get, "/v1/brand", ctx.token), 200)
      assert field(tenant, "sender_name")["source"] == "none"
    end

    test "TP-35: an http logo and an unknown subtenant are refused", ctx do
      http = %{"logo_url" => "http://example.com/a.png"}
      problem = F.body(patch(ctx.token, "/v1/brand", http), 422)
      assert [%{"pointer" => "/logo_url"}] = problem["errors"]

      unknown = "/v1/brand?subtenant=" <> Relay.ExternalId.encode("stn", Relay.Id.generate())
      assert code(F.request(:get, unknown, ctx.token), 404) == "subtenant_not_found"
      malformed = F.request(:get, "/v1/brand?subtenant=bad", ctx.token)
      assert code(malformed, 404) == "subtenant_not_found"
    end
  end
end
