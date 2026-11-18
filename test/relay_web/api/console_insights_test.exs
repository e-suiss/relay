defmodule RelayWeb.Api.ConsoleInsightsTest do
  use Relay.DataCase, async: false

  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp code(conn, status), do: F.body(conn, status)["code"]

  defp subscriber!(token, body) do
    id = "user-" <> TenantFixture.random()
    F.body(F.request(:post, "/v1/subscribers", token, Map.put(body, "external_id", id)), 201)
  end

  defp lookup(token, body), do: F.request(:post, "/v1/subscriber_lookups", token, body)

  defp day(offset), do: Relay.Clock.utc_now() |> DateTime.to_date() |> Date.add(offset)

  defp report(token, name) do
    path = "/v1/reports/#{name}?from=#{Date.to_iso8601(day(-1))}&to=#{Date.to_iso8601(day(1))}"
    F.request(:get, path, token)
  end

  describe "X-12 lookup by phone or e-mail" do
    test "X-12, X-5: a phone or e-mail finds its subscriber with masked fields", ctx do
      created =
        subscriber!(ctx.token, %{"email" => "ayse@example.com", "phone" => "+905321112233"})

      subscriber!(ctx.token, %{"email" => "other@example.com"})

      by_email = F.body(lookup(ctx.token, %{"email" => "AYSE@Example.com"}), 200)

      assert %{"object" => "subscriber_lookup", "truncated" => false, "data" => [found]} =
               by_email

      assert found["id"] == created["id"]
      assert found["email"] == "a***@example.com"
      assert found["phone"] == nil

      by_phone = F.body(lookup(ctx.token, %{"phone" => "+905321112233"}), 200)
      assert [%{"id" => id}] = by_phone["data"]
      assert id == created["id"]
    end

    test "X-5: an unknown address is an empty answer and two addresses are refused", ctx do
      assert F.body(lookup(ctx.token, %{"email" => "nobody@example.com"}), 200)["data"] == []

      body = %{"email" => "a@example.com", "phone" => "+905321112233"}
      assert code(lookup(ctx.token, body), 422) == "validation_failed"
      assert code(lookup(ctx.token, %{}), 422) == "validation_failed"
    end

    test "X-5: another tenant's subscriber is never found", ctx do
      subscriber!(ctx.token, %{"email" => "shared@example.com"})
      other = F.token(TenantFixture.tenant!().live)

      assert F.body(lookup(other, %{"email" => "shared@example.com"}), 200)["data"] == []
    end

    test "X-5: a shared address answers at most the contract's matches", ctx do
      max = Relay.Limits.fetch!(["subscriber_lookup", "max_matches"])
      for _n <- 0..max, do: subscriber!(ctx.token, %{"email" => "family@example.com"})

      body = F.body(lookup(ctx.token, %{"email" => "family@example.com"}), 200)
      assert length(body["data"]) == max
      assert body["truncated"] == true
    end
  end

  describe "X-12 rule dictionary" do
    test "X-12, X-1: the dictionary lists every rule with the sentence of each language", ctx do
      body = F.body(F.request(:get, "/v1/rules", ctx.token), 200)
      assert body["object"] == "rule_dictionary"

      dictionary = Relay.Rules.dictionary()
      assert length(body["data"]) == map_size(dictionary)

      for rule <- body["data"] do
        entry = Map.fetch!(dictionary, rule["rule_id"])
        assert rule["description"] == entry["description"]
        assert rule["outcome"] == entry["outcome"]
      end
    end
  end

  describe "TN-2 OP-19 tenant settings" do
    test "TN-2, OP-19: the settings show the defaults, the region and each retention class",
         ctx do
      :ok = TenantFixture.retention_periods!()
      body = F.body(F.request(:get, "/v1/settings", ctx.token), 200)

      {:ok, tenant} = Relay.Tenancy.tenant(ctx.scope)
      assert body["default_timezone"] == tenant["default_timezone"]
      assert body["default_locale"] == tenant["default_locale"]
      assert body["version"] == tenant["version"]

      classes = Enum.map(body["retention"], & &1["retention_class"])
      assert classes == ["commercial_message", "commercial_consent", "delivery_record"]

      unset = Enum.filter(body["retention"], &(&1["days"] == nil))
      assert Enum.all?(unset, &(&1["effective_days"] == &1["legal_days"]))
    end
  end

  describe "WF-14 where a route is used" do
    test "WF-14, X-10: the workflows and categories that name a route", ctx do
      tree = %{"single" => ["email", "sms"]}
      body = %{"key" => "critical", "name" => "Critical", "tree" => tree}
      F.body(F.request(:post, "/v1/routes", ctx.token, body), 201)

      category = %{
        "key" => "alerts",
        "name" => "Alerts",
        "message_class" => "transactional",
        "default_route" => "critical"
      }

      F.body(F.request(:post, "/v1/categories", ctx.token, category), 201)

      step = %{
        "type" => "channel",
        "key" => "notify",
        "route" => "critical",
        "template" => "order-shipped"
      }

      definition = Map.put(F.definition(category: "alerts"), "steps", [step])
      workflow = %{"key" => "alert-raised", "definition" => definition}
      F.body(F.request(:post, "/v1/workflows", ctx.token, workflow), 201)

      usage = F.body(F.request(:get, "/v1/routes/critical/usage", ctx.token), 200)
      assert usage["object"] == "route_usage"
      assert usage["categories"] == ["alerts"]

      assert [used] = usage["workflows"]
      assert %{"key" => "alert-raised", "state" => "draft", "version" => nil} = used
      assert used["steps"] == ["notify"]

      assert code(F.request(:get, "/v1/routes/missing/usage", ctx.token), 404) ==
               "route_policy_not_found"
    end
  end

  describe "AG-17 where an escalation policy is used" do
    test "AG-17, X-10: an unknown policy is not found", ctx do
      path = "/v1/escalation_policies/missing-policy/usage"

      assert code(F.request(:get, path, ctx.token), 404) == "escalation_policy_not_found"
    end
  end

  describe "X-10 publication gate before publishing" do
    test "X-10, WF-6: the workflow gate reports a missing route without publishing", ctx do
      :ok = F.category!(ctx.token, "orders")

      step = %{
        "type" => "channel",
        "key" => "notify",
        "route" => "missing",
        "template" => "order-shipped"
      }

      definition = Map.put(F.definition(), "steps", [step])
      workflow = %{"key" => "order-shipped", "definition" => definition}
      F.body(F.request(:post, "/v1/workflows", ctx.token, workflow), 201)

      path = "/v1/workflows/order-shipped/publication_check"
      check = F.body(F.request(:get, path, ctx.token), 200)
      assert check["object"] == "workflow_publication_check"
      assert check["publishable"] == false
      assert check["errors"] != []

      assert code(F.request(:get, "/v1/workflows/unknown/publication_check", ctx.token), 404) ==
               "workflow_not_found"
    end

    test "X-10, TP-32: the template gate's findings on the draft, without publishing", ctx do
      :ok = F.category!(ctx.token, "orders")

      definition = %{
        "default_locale" => "tr",
        "sensitivity" => "public",
        "cells" => %{"sms" => %{"tr" => %{"body" => "Siparisiniz yolda"}}}
      }

      template = %{
        "key" => "order-shipped",
        "name" => "Shipped",
        "category" => "orders",
        "definition" => definition
      }

      F.body(F.request(:post, "/v1/templates", ctx.token, template), 201)

      path = "/v1/templates/order-shipped/publication_check"
      check = F.body(F.request(:get, path, ctx.token), 200)
      assert check["object"] == "template_publication_check"
      assert is_boolean(check["publishable"])
      assert is_list(check["findings"])

      shown = F.body(F.request(:get, "/v1/templates/order-shipped", ctx.token), 200)
      assert check["checksum"] == shown["draft_checksum"]

      assert code(F.request(:get, "/v1/templates/unknown/publication_check", ctx.token), 404) ==
               "template_not_found"
    end
  end

  describe "AG-54 waitpoint figures" do
    test "AG-54, AG-49: a tenant without waitpoints counts zero", ctx do
      body = F.body(F.request(:get, "/v1/waitpoint_stats", ctx.token), 200)

      assert %{
               "object" => "waitpoint_stats",
               "open" => 0,
               "stalled" => 0,
               "silent" => 0,
               "resolved_last_7_days" => 0,
               "resolved_by_escalation_last_7_days" => 0,
               "held_notifications" => 0
             } = body

      assert body["evidence_levels_last_7_days"] == %{
               "channel_claim" => 0,
               "relay_session" => 0,
               "access_aas_ref" => 0
             }
    end
  end

  describe "DS-24 reports of A/B variants and render problems" do
    test "WF-50, TP-41, TP-26: the variant and render problem reports answer their period",
         ctx do
      assert %{"object" => "variant_report", "rows" => []} =
               F.body(report(ctx.token, "variants"), 200)

      assert %{"object" => "render_problem_report", "rows" => []} =
               F.body(report(ctx.token, "render_problems"), 200)
    end
  end
end
