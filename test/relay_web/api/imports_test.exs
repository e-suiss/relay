defmodule RelayWeb.Api.ImportsTest do
  use Relay.DataCase, async: false

  alias Relay.Api.Imports
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{scope: scope, token: F.token(scope), batch: "b-" <> TenantFixture.random()}
  end

  defp upload(token, type, batch, rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n"
    F.ndjson("/v1/imports?type=#{type}&batch=#{batch}", token, body)
  end

  defp imported!(ctx, type, rows, batch \\ nil) do
    started = F.body(upload(ctx.token, type, batch || ctx.batch, rows), 202)
    assert %{"object" => "import", "state" => "pending", "report" => nil} = started
    {:ok, id} = Relay.ExternalId.decode(started["id"], ["imp"])
    assert {:ok, :completed} = Imports.run(ctx.scope, id)
    assert {:ok, :not_pending} = Imports.run(ctx.scope, id)
    F.body(F.request(:get, "/v1/imports/" <> started["id"], ctx.token), 200)
  end

  defp ready!(ctx) do
    seed = %{"external_id" => "seed", "channel" => "email", "status" => "unknown"}
    imported!(ctx, "suppressions", [%{"channel" => "email", "address" => "x@example.com"}])
    imported!(ctx, "consents", [seed])
    :ok
  end

  defp codes(list), do: Enum.map(list, &{&1["line"], &1["code"]})

  defp later(days) do
    Relay.Clock.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.to_iso8601()
  end

  describe "OP-96 OP-55 imports" do
    test "OP-55 (2), OP-96: addresses, tokens and scheduled sends wait for the batch's suppressions and consents",
         ctx do
      for type <- ["subscribers", "devices", "scheduled"] do
        conn = upload(ctx.token, type, ctx.batch, [%{"external_id" => "u-1"}])
        assert F.body(conn, 409)["code"] == "import_order_violation"
      end

      imported!(ctx, "suppressions", [%{"channel" => "email", "address" => "x@example.com"}])
      conn = upload(ctx.token, "subscribers", ctx.batch, [%{"external_id" => "u-1"}])
      assert F.body(conn, 409)["code"] == "import_order_violation"

      ready!(ctx)
      assert F.body(upload(ctx.token, "subscribers", ctx.batch, [%{"external_id" => "u-1"}]), 202)
    end

    test "OP-96: a query that names no known type or batch is refused", ctx do
      conn = upload(ctx.token, "contacts", "bad batch", [%{}])
      body = F.body(conn, 422)
      assert body["code"] == "validation_failed"
      assert Enum.map(body["errors"], & &1["pointer"]) == ["/type", "/batch"]
    end

    test "OP-55 (7), OP-96: suppressions normalise phone numbers and put bad lines in the invalid bucket",
         ctx do
      report =
        imported!(ctx, "suppressions", [
          %{"channel" => "email", "address" => "blocked@example.com"},
          %{"channel" => "sms", "address" => "0532 000 00 01", "country" => "TR"},
          %{"channel" => "fax", "address" => "x"},
          %{"channel" => "sms", "address" => "12"}
        ])["report"]

      assert report["counts"]["written"] == 2
      assert codes(report["invalid"]) == [{3, "channel_invalid"}, {4, "phone_not_e164"}]
      assert is_list(report["data_residency"]["providers"])
    end

    test "OP-55 (3): a refusal wins, a grant needs its evidence and an unknown stays unknown",
         ctx do
      evidence = %{
        "occurred_at" => "2026-01-01T10:00:00Z",
        "consent_kind" => "explicit_opt_in",
        "recipient_type" => "individual",
        "text_version" => "v1",
        "evidence" => %{"form" => "signup"},
        "commercial" => false,
        "status" => "granted"
      }

      report =
        imported!(ctx, "consents", [
          %{"external_id" => "c-1", "channel" => "sms", "status" => "granted"},
          %{"external_id" => "c-1", "channel" => "sms", "status" => "refused"},
          %{"external_id" => "c-1", "channel" => "email", "status" => "granted"},
          Map.merge(evidence, %{"external_id" => "c-2", "channel" => "push"})
        ])["report"]

      assert report["consents"] == %{
               "refused" => 1,
               "granted" => 1,
               "iys_verified" => 0,
               "imported_unknown" => 1
             }

      assert codes(report["skipped"]) == [{1, "folded_consent"}]

      {:ok, recipient_id} = Relay.Subscribers.locate(ctx.scope, "c-1")
      {:ok, consents} = Relay.Preferences.get_consents(ctx.scope, recipient_id)
      by_channel = Map.new(consents, &{&1["channel"], &1})
      assert by_channel["sms"]["status"] == "revoked"
      assert %{"status" => "none", "source" => "imported_unknown"} = by_channel["email"]
    end

    test "OP-55 (5), OP-55 (2): conflicts are reported, the same id is merged and suppressions are counted",
         ctx do
      blocked = %{"channel" => "email", "address" => "blocked@example.com"}
      imported!(ctx, "suppressions", [blocked])
      ready!(ctx)

      report =
        imported!(ctx, "subscribers", [
          %{"external_id" => "s-1", "email" => "blocked@example.com", "locale" => "tr_TR"},
          %{"external_id" => "s-2", "email" => "blocked@example.com"},
          %{"external_id" => "s-3", "phone" => "12"},
          %{"external_id" => "s-4", "email" => "o@example.com", "digest_open_until" => later(1)},
          %{"external_id" => "s-1", "name" => "Ada"},
          %{"external_id" => "s-5", "email" => "clean@example.com", "provider_ref" => "os-77"}
        ])["report"]

      assert %{"field" => "email", "lines" => [2, 5]} in report["conflicts"] or
               %{"field" => "email", "lines" => [1, 2]} in report["conflicts"]

      assert codes(report["invalid"]) == [{3, "phone_not_e164"}]

      assert codes(report["skipped"]) == [
               {1, "merged_same_external_id"},
               {4, "digest_window_open"}
             ]

      assert report["suppression_check"] == %{
               "addresses" => 3,
               "suppressed" => 2,
               "expected" => 2,
               "verified" => true
             }

      assert {:ok, %{"locale" => "tr-TR"}} = Relay.Subscribers.fetch(ctx.scope, "s-1")
      assert {:ok, nil} = Relay.Subscribers.locate(ctx.scope, "s-4")
    end

    test "OP-55 (4): dead tokens are dropped, the newest token line stays and a device without an id is anonymous",
         ctx do
      ready!(ctx)

      device = fn token, extra ->
        Map.merge(%{"platform" => "fcm", "token" => token, "app" => "com.example.app"}, extra)
      end

      report =
        imported!(ctx, "devices", [
          device.("tok-a", %{"external_id" => "d-1", "last_seen_at" => "2026-01-01T00:00:00Z"}),
          device.("tok-a", %{"external_id" => "d-1", "last_seen_at" => "2026-06-01T00:00:00Z"}),
          device.("tok-dead", %{"external_id" => "d-1", "state" => "dead"}),
          device.("tok-anon", %{"provider_ref" => "player-9"}),
          device.("tok-bad", %{"platform" => "pager"})
        ])["report"]

      assert report["devices"] == %{
               "dead_dropped" => 1,
               "older_duplicates_dropped" => 1,
               "anonymous_subscribers" => 1,
               "last_seen_missing" => 1
             }

      assert report["counts"]["written"] == 2
      assert codes(report["invalid"]) == [{5, "platform_invalid"}]

      assert codes(report["skipped"]) == [{1, "older_duplicate_token"}, {3, "dead_token"}]
    end

    test "OP-96, OP-55 (9): templates are converted with their status and aliases expire within 90 days",
         ctx do
      report =
        imported!(ctx, "templates", [
          %{"key" => "welcome", "language" => "liquid", "source" => "Hi {{ name }}"},
          %{
            "key" => "promo",
            "language" => "handlebars",
            "source" => "{{#if vip}}{{firstName}}{{/if}}",
            "aliases" => %{"firstName" => "subscriber.first_name"},
            "aliases_expire_at" => later(30)
          },
          %{"key" => "footer", "language" => "handlebars", "source" => "{{> footer}}"},
          %{
            "key" => "late",
            "language" => "liquid",
            "source" => "x",
            "aliases" => %{"a" => "b"},
            "aliases_expire_at" => later(91)
          }
        ])["report"]

      assert [welcome, promo, footer] = report["templates"]
      assert %{"status" => "AUTO_OK", "output" => "Hi {{ name }}"} = welcome

      assert %{
               "status" => "NEEDS_REVIEW",
               "output" => "{% if vip %}{{ subscriber.first_name }}{% endif %}",
               "aliases" => [%{"name" => "firstName", "target" => "subscriber.first_name"}]
             } = promo

      assert %{"status" => "CANNOT", "output" => nil} = footer
      assert codes(report["invalid"]) == [{4, "alias_expiry_invalid"}]
    end
  end

  describe "OP-97 OP-56 cutover" do
    test "OP-97, OP-56: a scheduled send is added and confirmed before the legacy job is cancelled",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "reminder")
      external_id = "sch-" <> TenantFixture.random()
      body = %{"external_id" => external_id, "email" => "r@example.com"}
      F.body(F.request(:post, "/v1/subscribers", ctx.token, body), 201)
      ready!(ctx)

      rows = [
        %{
          "legacy_ref" => "job-1",
          "workflow" => "reminder",
          "subscriber_id" => external_id,
          "data" => %{"order" => "A-1"},
          "send_at" => later(1)
        },
        %{
          "legacy_ref" => "job-2",
          "workflow" => "reminder",
          "subscriber_id" => external_id,
          "send_at" => later(1),
          "digest_open_until" => later(2)
        }
      ]

      first = imported!(ctx, "scheduled", rows)["report"]

      assert [%{"line" => 1, "legacy_ref" => "job-1", "event_id" => "evt_" <> _}] =
               first["confirmations"]

      assert codes(first["skipped"]) == [{2, "digest_window_open"}]

      again = imported!(ctx, "scheduled", rows)["report"]
      assert again["confirmations"] == first["confirmations"]
      assert again["counts"]["unchanged"] == 1
    end

    test "OP-97, OP-56: a cron job is handed over in one call and its first run is a dry run",
         ctx do
      F.workflow!(ctx.scope, ctx.token, "reminder")
      external_id = "cron-" <> TenantFixture.random()
      body = %{"external_id" => external_id, "email" => "r@example.com"}
      F.body(F.request(:post, "/v1/subscribers", ctx.token, body), 201)

      yesterday = Relay.Clock.utc_now() |> DateTime.to_date() |> Date.add(-1) |> Date.to_iso8601()

      rule = %{
        "workflow" => "reminder",
        "subscriber_id" => external_id,
        "rrule" => "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
        "dtstart" => yesterday <> "T09:00:00",
        "data" => %{"order" => "A-1"}
      }

      handoff = %{"recurrence" => rule, "next_run_at" => "2000-01-01T00:00:00Z"}
      wrong = F.body(F.request(:post, "/v1/recurrence_handoffs", ctx.token, handoff), 422)
      assert wrong["code"] == "recurrence_handoff_mismatch"
      [expected] = Regex.run(~r/\d{4}-\d{2}-\d{2}T[0-9:]+Z/, wrong["detail"])

      handoff = %{handoff | "next_run_at" => expected} |> Map.put("cursor", "page-7")
      created = F.body(F.request(:post, "/v1/recurrence_handoffs", ctx.token, handoff), 201)

      assert %{"cursor" => "page-7", "last_run_at" => nil, "dry_run_pending" => true} =
               created["handoff"]

      {:ok, id} = Relay.ExternalId.decode(created["id"], ["rec"])
      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id)
      ms = DateTime.diff(row["fire_at"], Relay.Clock.business_now(ctx.scope), :millisecond)
      digest = TenantFixture.digest()
      actor = TenantFixture.actor()

      {:ok, {:advanced, _offset, _now}} =
        Relay.Platform.VirtualClock.advance(ctx.scope, max(ms, 0) + 1_000, digest, actor)

      assert :ok = Relay.Api.Recurrences.fire(ctx.scope, id)

      after_fire = F.body(F.request(:get, "/v1/recurrences/" <> created["id"], ctx.token), 200)

      assert after_fire["handoff"]["dry_run_pending"] == false

      assert %{"outcome" => "skipped", "event_id" => nil} = after_fire["last_occurrence"]
      assert after_fire["last_occurrence"]["rule_id"] == "recurrence.handoff_dry_run"
    end
  end
end
