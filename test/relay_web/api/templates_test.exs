defmodule RelayWeb.Api.TemplatesTest do
  use Relay.DataCase, async: false

  import Plug.Conn

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @key "order-shipped"
  @schema %{
    "type" => "object",
    "properties" => %{"order" => %{"type" => "string", "maxLength" => 200}},
    "required" => ["order"]
  }
  @accept %{"accept_warnings" => true}
  @approval %{
    "matched_terms" => ["borc"],
    "approved_by" => "ayse",
    "approved_at" => "2026-11-03T00:00:00Z"
  }

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    :ok = F.category!(token, "orders")
    %{scope: tenant.live, token: token}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp sms(body, extra \\ %{}) do
    Map.merge(
      %{
        "default_locale" => "tr",
        "sensitivity" => "public",
        "cells" => %{"sms" => %{"tr" => %{"body" => body}}}
      },
      extra
    )
  end

  defp push(body, extra) do
    cells = %{"push" => %{"tr" => %{"title" => "Kod", "body" => body}}}
    sms("x", Map.put(extra, "cells", cells))
  end

  defp create(token, key, definition) do
    body = %{"key" => key, "name" => "Shipped", "category" => "orders"}
    F.request(:post, "/v1/templates", token, Map.put(body, "definition", definition))
  end

  defp get(token, path), do: F.request(:get, path, token)

  defp etag(token, key) do
    [etag] = get_resp_header(get(token, "/v1/templates/" <> key), "etag")
    {"if-match", etag}
  end

  defp write(token, method, key, suffix, body \\ nil),
    do: F.request(method, "/v1/templates/" <> key <> suffix, token, body, [etag(token, key)])

  defp publish(token, key, body \\ %{}), do: write(token, :post, key, "/publish", body)

  defp redraft(token, key, definition),
    do: write(token, :put, key, "", %{"definition" => definition})

  defp promote(token, key, number), do: write(token, :post, key, "/versions/#{number}/promote")

  defp workflow!(ctx, schema \\ @schema),
    do: F.workflow!(ctx.scope, ctx.token, "order-flow", channels: ["sms"], event_schema: schema)

  defp produce(token, key, definition) do
    body = %{"name" => "OTP", "category" => "security", "definition" => definition}
    F.request(:put, "/v1/producer_templates/" <> key, token, Map.merge(body, @accept))
  end

  defp audit(scope, action) do
    now = DateTime.utc_now()

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status ->
        Relay.Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())]
        )
      end)

    rows
  end

  describe "API-69 TP-48 template resources" do
    test "API-69, TP-48: create answers 201 with an ETag and its draft; reads and lists it", ctx do
      conn = create(ctx.token, @key, sms("Kargoda"))
      body = F.body(conn, 201)

      assert "tpl_" <> _ = body["id"]

      assert %{
               "object" => "template",
               "key" => @key,
               "owner" => "tenant",
               "protected" => false,
               "category" => "orders",
               "message_class" => "transactional",
               "type" => "transactional",
               "state" => "active",
               "live_version" => nil,
               "version" => 1
             } = body

      assert body["draft"]["cells"] == %{"sms" => %{"tr" => %{"body" => "Kargoda"}}}
      assert body["draft_checksum"] =~ ~r/\A[0-9a-f]{64}\z/
      assert get_resp_header(conn, "etag") == [~s("1")]

      assert code(create(ctx.token, @key, sms("x")), 409) == "resource_conflict"
      assert F.body(get(ctx.token, "/v1/templates/" <> @key), 200)["id"] == body["id"]

      listed = F.body(get(ctx.token, "/v1/templates"), 200)
      assert Enum.map(listed["data"], & &1["key"]) == [@key]
      assert code(get(ctx.token, "/v1/templates/missing"), 404) == "template_not_found"
      assert length(audit(ctx.scope, "template.created")) == 1
    end

    test "TP-56, TP-52: unsupported locales and a tenant producer brand are refused", ctx do
      zz = %{"default_locale" => "zz", "cells" => %{"sms" => %{"zz" => %{"body" => "x"}}}}
      assert code(create(ctx.token, "a", zz), 422) == "locale_not_supported"

      branded = sms("x", %{"producer_brand" => %{"footer" => "x"}})
      problem = F.body(create(ctx.token, "b", branded), 422)
      assert [%{"pointer" => "/definition/producer_brand"}] = problem["errors"]
    end

    test "S-66, INV-21: a draft is replaced under If-Match and a name change is kept", ctx do
      F.body(create(ctx.token, @key, sms("Kargoda")), 201)
      body = %{"name" => "Shipped today", "definition" => sms("Yolda")}
      path = "/v1/templates/" <> @key

      assert code(F.request(:put, path, ctx.token, body), 428) == "precondition_required"
      stale = F.request(:put, path, ctx.token, body, [{"if-match", ~s("9")}])
      assert code(stale, 412) == "precondition_failed"

      fresh = F.body(write(ctx.token, :put, @key, "", body), 200)
      assert fresh["name"] == "Shipped today"
      assert fresh["draft"]["cells"]["sms"]["tr"]["body"] == "Yolda"
      assert fresh["version"] == 3
    end
  end

  describe "TP-31 TP-32 publication" do
    test "TP-32, TP-14: a hard finding refuses the publication with every finding", ctx do
      F.body(create(ctx.token, @key, sms("{{ order }}")), 201)
      problem = F.body(publish(ctx.token, @key), 422)

      assert problem["code"] == "template_gate_failed"
      assert [finding] = problem["findings"]
      assert %{"check" => "variables", "level" => "hard", "channel" => "sms"} = finding
      assert finding["locale"] == "tr"
    end

    test "TP-32, TP-15: warnings publish only when accepted and are recorded on the version", ctx do
      workflow!(ctx)
      F.body(create(ctx.token, @key, sms("Merhaba {{ order }}")), 201)

      problem = F.body(publish(ctx.token, @key), 422)
      assert problem["code"] == "template_warnings_unacknowledged"
      assert [%{"check" => "sms_segments", "level" => "warning"}] = problem["findings"]

      version = F.body(publish(ctx.token, @key, @accept), 200)

      assert %{
               "object" => "template_version",
               "version" => 1,
               "state" => "published",
               "live" => true,
               "warnings_accepted" => true,
               "variables" => %{"always" => ["order"], "conditional" => []}
             } = version

      assert "tpv_" <> _ = version["id"]
      assert [%{"check" => "sms_segments"}] = version["findings"]
      assert version["measures"]["sms"]["tr"]["sms"]["segments"] > 1

      assert code(publish(ctx.token, @key), 409) == "template_no_draft"
      assert [_] = audit(ctx.scope, "template.published")
    end

    test "TP-31: a checksum names the reviewed draft and identical content is no new version",
         ctx do
      workflow!(ctx)
      F.body(create(ctx.token, @key, sms("Sipariş {{ order }}")), 201)
      stale = Map.put(@accept, "checksum", String.duplicate("0", 64))

      assert code(publish(ctx.token, @key, stale), 409) == "template_draft_changed"
      F.body(publish(ctx.token, @key, @accept), 200)

      F.body(redraft(ctx.token, @key, sms("Sipariş {{ order }}")), 200)
      assert code(publish(ctx.token, @key, @accept), 409) == "template_version_duplicate"
    end

    test "TP-31: versions are listed and read; a promotion revalidates the version", ctx do
      workflow!(ctx)
      F.body(create(ctx.token, @key, sms("Sipariş {{ order }}")), 201)
      F.body(publish(ctx.token, @key, @accept), 200)
      F.body(redraft(ctx.token, @key, sms("Kargoda")), 200)
      F.body(publish(ctx.token, @key, @accept), 200)

      listed = F.body(get(ctx.token, "/v1/templates/#{@key}/versions"), 200)
      assert Enum.map(listed["data"], & &1["version"]) == [2, 1]

      first = F.body(get(ctx.token, "/v1/templates/#{@key}/versions/1"), 200)
      assert first["live"] == false
      assert first["definition"]["cells"]["sms"]["tr"]["body"] == "Sipariş {{ order }}"

      assert F.body(promote(ctx.token, @key, 1), 200)["live_version"] == 1
      assert code(promote(ctx.token, @key, 9), 404) == "template_version_not_found"

      narrowed = %{"type" => "object", "properties" => %{}}
      body = %{"definition" => F.definition(channels: ["sms"], event_schema: narrowed)}
      [match] = get_resp_header(get(ctx.token, "/v1/workflows/order-flow"), "etag")
      path = "/v1/workflows/order-flow"
      F.body(F.request(:put, path, ctx.token, body, [{"if-match", match}]), 200)
      F.publish!(ctx.scope, ctx.token, "order-flow")

      assert F.body(promote(ctx.token, @key, 2), 200)["live_version"] == 2
      assert code(promote(ctx.token, @key, 1), 422) == "template_gate_failed"
    end

    test "TP-21, TP-46: a sensitive term needs the class confirmed against the terms", ctx do
      workflow!(ctx)
      F.body(create(ctx.token, @key, sms("Borcunuz {{ order }}")), 201)

      problem = F.body(publish(ctx.token, @key, @accept), 422)
      assert problem["code"] == "template_sensitivity_unconfirmed"
      assert problem["detail"] =~ "borc"

      confirmed = %{"sensitivity" => "personal", "sensitivity_approval" => @approval}
      F.body(redraft(ctx.token, @key, sms("Borcunuz {{ order }}", confirmed)), 200)
      F.body(publish(ctx.token, @key, @accept), 200)
    end

    test "TP-30: the translation matrix shows every cell; a machine translation blocks", ctx do
      cells = %{
        "sms" => %{
          "tr" => %{"body" => "Kargoda"},
          "en" => %{"body" => "Shipped", "machine_translated" => true}
        },
        "push" => %{"tr" => %{"title" => "Kargo", "body" => "Kargoda"}}
      }

      F.body(create(ctx.token, @key, sms("x", %{"cells" => cells})), 201)
      matrix = F.body(get(ctx.token, "/v1/templates/#{@key}/translations"), 200)
      statuses = Map.new(matrix["cells"], &{{&1["channel"], &1["locale"]}, &1["status"]})

      assert matrix["source"] == "draft"
      assert matrix["locales"] == ["en", "tr"]
      assert statuses[{"sms", "en"}] == "machine_translated"
      assert statuses[{"sms", "tr"}] == "present"
      assert statuses[{"push", "en"}] == "missing"

      assert code(publish(ctx.token, @key), 422) == "template_translation_unapproved"

      bad = get(ctx.token, "/v1/templates/#{@key}/translations?source=other")
      assert code(bad, 422) == "validation_failed"
    end

    test "TP-48: an archived template keeps its rows and refuses a publication", ctx do
      F.body(create(ctx.token, @key, sms("Kargoda")), 201)

      assert F.body(write(ctx.token, :post, @key, "/archive"), 200)["state"] == "archived"
      assert code(publish(ctx.token, @key), 409) == "template_archived"
    end

    test "API-75: writes need the config scope; reads are open to read", ctx do
      read = F.token(ctx.scope, ["read"])
      assert code(create(read, @key, sms("x")), 403) == "auth_insufficient_scope"
      assert F.body(get(read, "/v1/templates"), 200)["data"] == []
    end
  end

  describe "TP-37 TP-52 producer templates" do
    setup do
      platform = TenantFixture.tenant!(platform_product: "access")
      %{platform: platform.live, producer: F.token(platform.live)}
    end

    test "TP-52: a platform product publishes a protected template the tenant cannot change",
         ctx do
      version = F.body(produce(ctx.producer, "otp-code", sms("Kodunuz hazır")), 200)
      assert version["version"] == 1

      shown = F.body(get(ctx.producer, "/v1/templates/otp-code"), 200)
      assert %{"owner" => "producer", "product" => "access", "protected" => true} = shown

      changed = redraft(ctx.producer, "otp-code", sms("x"))
      assert code(changed, 409) == "template_protected"
      assert code(write(ctx.producer, :post, "otp-code", "/archive"), 409) == "template_protected"

      again = F.body(produce(ctx.producer, "otp-code", sms("Yeni kodunuz hazır")), 200)
      assert again["version"] == 2

      same = produce(ctx.producer, "otp-code", sms("Yeni kodunuz hazır"))
      assert code(same, 409) == "template_version_duplicate"
    end

    test "TP-52: a tenant key is protected from the producer; only a platform product produces",
         ctx do
      :ok = F.category!(ctx.producer, "orders")
      F.body(create(ctx.producer, @key, sms("Kargoda")), 201)
      assert code(produce(ctx.producer, @key, sms("x")), 409) == "template_protected"

      assert code(produce(ctx.token, "otp-code", sms("x")), 403) == "template_producer_required"
    end

    test "TP-52, TP-36: the tenant overrides only the four brand fields of a producer template",
         ctx do
      produced = %{"logo_url" => "https://access.example/logo.png", "legal_name" => "Access A.Ş."}
      body = "{{ brand.logo_url }} {{ brand.legal_name }}"
      F.body(produce(ctx.producer, "otp-code", push(body, %{"producer_brand" => produced})), 200)

      patch = %{"logo_url" => "https://tenant.example/logo.png", "legal_name" => "Kiracı A.Ş."}
      merge = [{"content-type", "application/merge-patch+json"}]
      F.body(F.request(:patch, "/v1/brand", ctx.producer, patch, merge), 200)

      opts = [message_class: "security", channels: ["push"]]
      F.workflow!(ctx.platform, ctx.producer, "otp-flow", opts)
      preview = %{"workflow" => "otp-flow", "data" => %{}}
      conn = F.request(:post, "/v1/templates/otp-code/preview", ctx.producer, preview)

      [%{"content" => %{"body" => text}}] = F.body(conn, 200)["renders"]
      assert text =~ "tenant.example"
      assert text =~ "Access A.Ş."
    end
  end
end
