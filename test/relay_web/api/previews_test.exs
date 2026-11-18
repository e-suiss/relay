defmodule RelayWeb.Api.PreviewsTest do
  use Relay.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Plug.Conn

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @endpoint RelayWeb.Endpoint

  @key "order-shipped"
  @schema %{
    "type" => "object",
    "properties" => %{"order" => %{"type" => "string", "maxLength" => 40}},
    "required" => ["order"],
    "examples" => [%{"order" => "A-1"}]
  }
  @accept %{"accept_warnings" => true}

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    %{scope: tenant.live, token: token}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp template!(token, cells) do
    definition = %{"default_locale" => "tr", "sensitivity" => "public", "cells" => cells}
    body = %{"key" => @key, "name" => "Shipped", "category" => "orders"}
    F.body(F.request(:post, "/v1/templates", token, Map.put(body, "definition", definition)), 201)
  end

  defp publish!(token) do
    [etag] = get_resp_header(F.request(:get, "/v1/templates/" <> @key, token), "etag")
    path = "/v1/templates/#{@key}/publish"
    F.body(F.request(:post, path, token, @accept, [{"if-match", etag}]), 200)
  end

  defp preview(token, body) do
    body = Map.put_new(body, "workflow", "order-flow")
    F.request(:post, "/v1/templates/#{@key}/preview", token, body)
  end

  defp workflow!(ctx, key \\ "order-flow", opts \\ []) do
    defaults = [event_schema: @schema, channels: ["sms", "email"], template: false]
    opts = Keyword.merge(defaults, opts)
    F.workflow!(ctx.scope, ctx.token, key, opts)
  end

  defp sms(body), do: %{"sms" => %{"tr" => %{"body" => body}}}

  describe "API-60 TP-38 template preview" do
    test "API-60, TP-53, TP-39: an SMS render carries its encoding, segments and characters",
         ctx do
      workflow!(ctx)
      template!(ctx.token, sms("Çağrı {{ order }}"))
      conn = preview(ctx.token, %{})
      body = F.body(conn, 200)

      assert %{"object" => "template_preview", "version" => "draft"} = body
      assert body["sample"] == "schema_examples"

      assert [render] = body["renders"]
      assert %{"channel" => "sms", "locale" => "tr", "failure_reason" => nil} = render
      assert render["content"]["body"] == "Çağrı A-1"

      assert render["sms"] == %{
               "encoding" => "GSM7_TR",
               "encoding_unverified_provider" => "UCS2",
               "segments" => 1,
               "characters" => 9
             }

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "sandbox"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "API-60, TP-41: data without a required variable is a missing_variable render", ctx do
      workflow!(ctx)
      template!(ctx.token, sms("Sipariş {{ order }}"))
      body = F.body(preview(ctx.token, %{"data" => %{}}), 200)

      assert body["sample"] == "data"
      assert [render] = body["renders"]
      assert render["failure_reason"] == "missing_variable"
      assert [%{"code" => "missing_variable", "variable" => "order"}] = render["warnings"]
    end

    test "TP-38: the boundary sample fills strings to maxLength and a variant can be missing",
         ctx do
      workflow!(ctx)
      template!(ctx.token, sms("{{ order }}"))
      body = %{"sample" => "boundary", "channels" => ["sms", "push"]}
      rendered = F.body(preview(ctx.token, body), 200)

      assert rendered["sample"] == "boundary"
      assert [sms, push] = rendered["renders"]
      assert sms["content"]["body"] == String.duplicate("x", 40)
      assert [%{"code" => "variant_missing"}] = push["warnings"]
      assert push["content"] == nil
    end

    test "TP-47: masked recent events keep lengths; events without content are left out", ctx do
      workflow!(ctx, "order-flow", event_schema: Map.delete(@schema, "examples"))
      template!(ctx.token, sms("Sayın {{ order }}"))
      to = [%{"id" => "u-1", "email" => "a@example.com"}]
      event = %{"workflow" => "order-flow", "to" => to, "data" => %{"order" => "Mehmet Yılmaz"}}
      F.body(F.request(:post, "/v1/events", ctx.token, event), 202)

      body = F.body(preview(ctx.token, %{"sample" => "masked_recent"}), 200)
      assert [%{"content" => %{"body" => "Sayın Xxxxxx Xxxxxx"}}] = body["renders"]

      workflow!(ctx, "quiet-flow", event_schema: Map.delete(@schema, "examples"))
      quiet = Map.merge(event, %{"workflow" => "quiet-flow", "retention" => "none"})
      F.body(F.request(:post, "/v1/events", ctx.token, quiet), 202)

      masked = %{"workflow" => "quiet-flow", "sample" => "masked_recent"}
      assert code(preview(ctx.token, masked), 422) == "preview_sample_unavailable"
      fallback = F.body(preview(ctx.token, %{"workflow" => "quiet-flow"}), 200)
      assert fallback["sample"] == "boundary"
    end

    test "API-60: a version and the workflow must exist; a locale must be supported", ctx do
      workflow!(ctx)
      template!(ctx.token, sms("{{ order }}"))

      assert code(preview(ctx.token, %{"version" => "live"}), 404) == "template_version_not_found"
      assert code(preview(ctx.token, %{"workflow" => "nope"}), 404) == "workflow_not_found"
      assert code(preview(ctx.token, %{"locale" => "zz"}), 422) == "locale_not_supported"
    end

    test "TP-8, TP-22: an MJML email is compiled for the preview and rendered as data", ctx do
      workflow!(ctx)

      html =
        "<mjml><mj-body><mj-section><mj-column><mj-text>Merhaba {{ order }}</mj-text>" <>
          "</mj-column></mj-section></mj-body></mjml>"

      cell = %{"subject" => "Sipariş {{ order }}", "html" => html}
      cell = Map.put(cell, "text", "Merhaba {{ order }}")
      template!(ctx.token, %{"email" => %{"tr" => cell}})

      [render] = F.body(preview(ctx.token, %{}), 200)["renders"]
      assert render["content"]["html"] =~ "Merhaba A-1"
      assert render["content"]["text"] == "Merhaba A-1"
      assert render["content"]["subject"] == "Sipariş A-1"
    end
  end

  describe "API-60 TP-11 workflow preview" do
    test "API-60, TP-51: each step says whether it would send and the template rule that stops it",
         ctx do
      workflow!(ctx)
      path = "/v1/workflows/order-flow/preview"

      before = F.body(F.request(:post, path, ctx.token, %{}), 200)
      assert %{"object" => "workflow_preview", "version" => "live"} = before
      assert Enum.all?(before["steps"], &(&1["rule_id"] == "template.not_published"))

      template!(ctx.token, sms("Sipariş {{ order }}"))
      publish!(ctx.token)

      steps = F.body(F.request(:post, path, ctx.token, %{}), 200)["steps"]
      by_channel = Map.new(steps, &{&1["channel"], &1})

      assert %{"would_send" => true, "rule_id" => nil} = by_channel["sms"]
      assert by_channel["sms"]["render"]["content"]["body"] == "Sipariş A-1"
      assert %{"would_send" => false, "rule_id" => rule} = by_channel["email"]
      assert rule == "template.variant_missing"

      assert code(F.request(:post, path, ctx.token, %{"to" => "nobody"}), 422) ==
               "recipient_not_found"

      missing = F.request(:post, "/v1/workflows/none/preview", ctx.token, %{})
      assert code(missing, 404) == "workflow_not_found"
    end
  end

  describe "TP-24 TP-39 sandboxed preview origin" do
    defp email_template!(token, extra, cell) do
      cells = %{"email" => %{"tr" => cell}}
      definition = %{"default_locale" => "tr", "sensitivity" => "public", "cells" => cells}
      body = %{"key" => @key, "name" => "Shipped", "category" => "orders"}
      template = Map.put(body, "definition", Map.merge(definition, extra))
      F.body(F.request(:post, "/v1/templates", token, template), 201)
    end

    defp email_render(token) do
      [render] = F.body(preview(token, %{"channels" => ["email"]}), 200)["renders"]
      render
    end

    defp mjml(text) do
      "<mjml><mj-body><mj-section><mj-column><mj-text>" <>
        text <> "</mj-text></mj-column></mj-section></mj-body></mjml>"
    end

    test "TP-39, TP-24: raw_html output leaves the JSON answer and is served on the preview host",
         ctx do
      workflow!(ctx)
      html = "<p>Merhaba {{ order }}</p><script>alert(1)</script>"
      cell = %{"subject" => "Sipariş", "html_kind" => "raw_html", "html" => html, "text" => "M"}
      email_template!(ctx.token, %{}, cell)

      render = email_render(ctx.token)
      assert render["content"]["html"] == nil
      assert render["content"]["subject"] == "Sipariş"
      assert "https://preview.relay.test/sandbox/" <> token = render["sandbox_url"]

      page = get(build_conn(), render["sandbox_url"])
      assert page.status == 200
      assert page.resp_body =~ "Merhaba A-1"
      assert ["text/html" <> _] = get_resp_header(page, "content-type")
      assert [csp] = get_resp_header(page, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "; sandbox"
      assert csp =~ "frame-ancestors " <> RelayWeb.Endpoint.url()
      refute csp =~ "script-src"
      assert get_resp_header(page, "cache-control") == ["no-store"]
      assert get_resp_header(page, "x-frame-options") == []

      api_host = get(build_conn(), "https://localhost/sandbox/" <> token)
      assert api_host.status == 404
      assert api_host.resp_body == ""

      unknown = get(build_conn(), "https://preview.relay.test/sandbox/" <> String.reverse(token))
      assert unknown.status == 404

      forged = Base.url_encode64(<<0::128, 0>> <> :crypto.strong_rand_bytes(32), padding: false)
      assert get(build_conn(), "https://preview.relay.test/sandbox/" <> forged).status == 404
    end

    test "TP-24: a template that allows the raw filter keeps its HTML out of the JSON answer",
         ctx do
      workflow!(ctx)
      cell = %{"subject" => "S", "html" => mjml("Merhaba {{ order | raw }}"), "text" => "M"}
      email_template!(ctx.token, %{"allow_raw" => true}, cell)

      render = email_render(ctx.token)
      assert render["content"]["html"] == nil
      assert get(build_conn(), render["sandbox_url"]).resp_body =~ "Merhaba A-1"
    end

    test "TP-39: an escaped e-mail keeps its HTML as data and also gets a sandbox link", ctx do
      workflow!(ctx)
      cell = %{"subject" => "S", "html" => mjml("Merhaba {{ order }}"), "text" => "M"}
      email_template!(ctx.token, %{}, cell)

      render = email_render(ctx.token)
      assert render["content"]["html"] =~ "Merhaba A-1"
      assert "https://preview.relay.test/sandbox/" <> _token = render["sandbox_url"]
    end

    test "TP-39: without a preview host the raw HTML is withheld with a warning", ctx do
      workflow!(ctx)
      previous = Application.get_env(:relay, Relay.Api.PreviewSandbox)
      Application.put_env(:relay, Relay.Api.PreviewSandbox, host: nil)
      on_exit(fn -> Application.put_env(:relay, Relay.Api.PreviewSandbox, previous) end)

      cell = %{"subject" => "S", "html_kind" => "raw_html", "html" => "<p>x</p>", "text" => "M"}
      email_template!(ctx.token, %{}, cell)

      render = email_render(ctx.token)
      assert render["content"]["html"] == nil
      assert render["sandbox_url"] == nil
      assert "sandbox_unconfigured" in Enum.map(render["warnings"], & &1["code"])
    end
  end
end
