defmodule RelayWeb.Api.EmailTrackingTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, token: F.token(tenant.live)}
  end

  defp category!(token, key, class) do
    body = %{"key" => key, "name" => "Name of " <> key, "message_class" => class}
    F.body(F.request(:post, "/v1/categories", token, body), 201)
  end

  defp put(token, path, body), do: F.request(:put, path, token, body)

  describe "CH-43 DS-29 DS-32 e-mail tracking settings" do
    test "DS-29: tracking is off until the tenant turns it on for a category", ctx do
      category!(ctx.token, "news", "marketing")
      path = "/v1/categories/news/email_tracking"

      off = F.body(F.request(:get, path, ctx.token), 200)

      assert %{"object" => "email_tracking", "target" => "category", "key" => "news"} = off
      assert %{"open_pixel" => false, "wrap_links" => false, "trackable" => true} = off
      assert off["warnings"] == []

      on = F.body(put(ctx.token, path, %{"open_pixel" => true, "wrap_links" => true}), 200)
      assert %{"open_pixel" => true, "wrap_links" => true} = on
      assert on["warnings"] == ["open_pixel_unreliable"]

      assert F.body(F.request(:get, path, ctx.token), 200)["wrap_links"] == true

      {:ok, settings} =
        Relay.Repo.in_scope(ctx.scope, fn _status ->
          Relay.TemplateStore.tenant_setting("email.tracking.category.news")
        end)

      assert settings == %{"open_pixel" => true, "wrap_links" => true}
    end

    test "CH-43, CH-44: a security category can never be tracked", ctx do
      category!(ctx.token, "alerts", "security")
      path = "/v1/categories/alerts/email_tracking"

      problem = F.body(put(ctx.token, path, %{"open_pixel" => false, "wrap_links" => true}), 422)
      assert [%{"pointer" => "/wrap_links", "code" => "not_allowed"}] = problem["errors"]

      off = F.body(put(ctx.token, path, %{"open_pixel" => false, "wrap_links" => false}), 200)
      assert off["trackable"] == false
    end

    test "DS-29: an unknown category or template is not found", ctx do
      body = %{"open_pixel" => true, "wrap_links" => true}
      missing = F.body(put(ctx.token, "/v1/categories/nowhere/email_tracking", body), 404)
      assert missing["code"] == "category_not_found"

      template = F.request(:get, "/v1/templates/no-such-template/email_tracking", ctx.token)
      assert F.body(template, 404)["code"] == "template_not_found"
    end
  end
end
