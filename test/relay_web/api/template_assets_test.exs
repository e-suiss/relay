defmodule RelayWeb.Api.TemplateAssetsTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @accept %{"accept_warnings" => true}
  @open "<mjml><mj-body><mj-section><mj-column><mj-text>"
  @close "</mj-text></mj-column></mj-section></mj-body></mjml>"

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    :ok = F.category!(token, "orders")
    %{scope: tenant.live, token: token}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]
  defp get(token, path), do: F.request(:get, path, token)

  defp create(token, collection, key, definition) do
    body = %{"key" => key, "name" => "Main", "definition" => definition}
    F.request(:post, "/v1/" <> collection, token, body)
  end

  defp etag(token, path) do
    [etag] = get_resp_header(get(token, path), "etag")
    {"if-match", etag}
  end

  defp write(token, collection, key, suffix, body \\ nil) do
    path = "/v1/#{collection}/#{key}"
    F.request(:post, path <> suffix, token, body, [etag(token, path)])
  end

  defp layout(text),
    do: %{"mjml" => @open <> text <> @close, "text_footer" => "{{ legal_footer }}"}

  describe "TP-35 layouts" do
    test "TP-35, TP-8: a layout compiles at publication and its versions are read", ctx do
      body = F.body(create(ctx.token, "layouts", "main", layout("{{ brand.sender_name }}")), 201)
      assert %{"object" => "layout", "owner" => "tenant", "live_version" => nil} = body
      assert "lay_" <> _ = body["id"]

      version = F.body(write(ctx.token, "layouts", "main", "/publish", @accept), 200)
      assert %{"object" => "layout_version", "layout_key" => "main", "version" => 1} = version
      assert version["live"] == true
      assert "lyv_" <> _ = version["id"]

      assert F.body(get(ctx.token, "/v1/layouts/main"), 200)["live_version"] == 1
      listed = F.body(get(ctx.token, "/v1/layouts/main/versions"), 200)
      assert Enum.map(listed["data"], & &1["version"]) == [1]

      read = F.body(get(ctx.token, "/v1/layouts/main/versions/1"), 200)
      assert read["definition"]["text_footer"] == "{{ legal_footer }}"
      missing = get(ctx.token, "/v1/layouts/main/versions/2")
      assert code(missing, 404) == "layout_version_not_found"
    end

    test "TP-58, TP-8: default icons and MJML that does not compile refuse the publication", ctx do
      social =
        ~s(<mjml><mj-body><mj-section><mj-column><mj-social>) <>
          ~s(<mj-social-element name="github" href="https://e.x">G</mj-social-element>) <>
          ~s(</mj-social></mj-column></mj-section></mj-body></mjml>)

      F.body(create(ctx.token, "layouts", "social", %{"mjml" => social}), 201)
      problem = F.body(write(ctx.token, "layouts", "social", "/publish", @accept), 422)
      assert problem["code"] == "template_gate_failed"
      assert "mjml_default_asset" in Enum.map(problem["findings"], & &1["check"])

      F.body(create(ctx.token, "layouts", "broken", %{"mjml" => "<p>not mjml</p>"}), 201)
      problem = F.body(write(ctx.token, "layouts", "broken", "/publish", @accept), 422)
      assert "mjml_compile" in Enum.map(problem["findings"], & &1["check"])
    end

    test "TP-35, TP-48: a template needs the live layout, which then cannot be archived", ctx do
      F.body(create(ctx.token, "layouts", "main", layout("Merhaba")), 201)

      cell = %{"subject" => "Sipariş", "html_kind" => "raw_html", "html" => "<p>Merhaba</p>"}
      cells = %{"email" => %{"tr" => Map.put(cell, "text", "Merhaba")}}
      definition = %{"default_locale" => "tr", "sensitivity" => "public", "layout" => "main"}
      body = %{"key" => "welcome", "name" => "Welcome", "category" => "orders"}
      template = Map.put(body, "definition", Map.put(definition, "cells", cells))
      F.body(F.request(:post, "/v1/templates", ctx.token, template), 201)

      unpublished = write(ctx.token, "templates", "welcome", "/publish", @accept)
      assert code(unpublished, 422) == "layout_not_published"

      F.body(write(ctx.token, "layouts", "main", "/publish", @accept), 200)
      F.body(write(ctx.token, "templates", "welcome", "/publish", @accept), 200)

      assert code(write(ctx.token, "layouts", "main", "/archive"), 409) == "layout_in_use"
    end

    test "TP-31: a layout version is promoted back to live", ctx do
      F.body(create(ctx.token, "layouts", "main", layout("Bir")), 201)
      F.body(write(ctx.token, "layouts", "main", "/publish", @accept), 200)

      path = "/v1/layouts/main"
      draft = %{"definition" => layout("İki")}
      F.body(F.request(:put, path, ctx.token, draft, [etag(ctx.token, path)]), 200)
      F.body(write(ctx.token, "layouts", "main", "/publish", @accept), 200)

      promoted = F.body(write(ctx.token, "layouts", "main", "/versions/1/promote"), 200)
      assert promoted["live_version"] == 1
    end
  end

  describe "TP-35 partials" do
    test "TP-35, TP-59: a partial publishes with complete icu forms and is refused without", ctx do
      ok = %{"default_locale" => "tr", "bodies" => %{"tr" => "Merhaba", "en" => "Hello"}}
      body = F.body(create(ctx.token, "partials", "greeting", ok), 201)
      assert %{"object" => "partial", "draft" => ^ok} = body

      version = F.body(write(ctx.token, "partials", "greeting", "/publish"), 200)
      assert %{"object" => "partial_version", "partial_key" => "greeting"} = version

      icu = ~s({{ "{n, plural, other {#}}" | icu: n: 1 }})
      bad = %{"default_locale" => "tr", "bodies" => %{"tr" => icu}}
      F.body(create(ctx.token, "partials", "count", bad), 201)
      problem = F.body(write(ctx.token, "partials", "count", "/publish"), 422)

      assert [%{"check" => "icu_categories", "detail" => %{"missing" => ["one"]}}] =
               problem["findings"]

      unsupported = %{"default_locale" => "zz", "bodies" => %{"zz" => "x"}}
      assert code(create(ctx.token, "partials", "zz", unsupported), 422) == "validation_failed"
    end
  end
end
