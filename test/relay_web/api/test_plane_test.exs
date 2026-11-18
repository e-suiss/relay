defmodule RelayWeb.Api.TestPlaneTest do
  use Relay.DataCase, async: false

  alias Relay.Api.TestPlane.Seeder
  alias Relay.Channels.Simulated
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @seeder "Relay.Api.TestPlane.Seeder"
  @seeds ~w(seed_no_consent seed_opted_out seed_quiet_hours seed_capped seed_bounced
            seed_no_device seed_fallback_timezone)

  setup do
    Application.put_env(:relay, Relay.Tenancy.Provisioning, test_plane: Relay.Api.TestPlane)
    on_exit(fn -> Application.put_env(:relay, Relay.Tenancy.Provisioning, test_plane: nil) end)
    tenant = TenantFixture.tenant!()

    %{
      tenant: tenant,
      scope: tenant.test,
      token: F.token(tenant.test),
      live_token: F.token(tenant.live)
    }
  end

  defp seed!(scope) do
    args = Relay.Scope.to_job_args(scope)
    assert Seeder.perform(%Oban.Job{args: args}) == :ok
  end

  defp get(token, path), do: F.body(F.request(:get, path, token), 200)

  defp recipient_id(scope, external_id) do
    {:ok, [index]} = Relay.Subscribers.indexes(scope, [external_id])
    resolve = fn _status -> Relay.Subscribers.resolve_indexes([index]) end
    {:ok, [id]} = Repo.in_scope(scope, resolve)
    id
  end

  defp run_sends(scope) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT args FROM relay_queue.oban_jobs
        WHERE worker = 'Relay.Delivery.Send' AND args->>'tenant_id' = $1
          AND state IN ('available', 'scheduled')
        ORDER BY id
        """,
        [Relay.Scope.tenant_text(scope)]
      )

    for [args] <- rows, do: Relay.Delivery.Send.perform(%Oban.Job{args: args, attempt: 1})
  end

  defp message(token, notification_id) do
    body = get(token, "/v1/test/inbox")
    Enum.find(body["data"], &(&1["notification_id"] == notification_id))
  end

  describe "X-43 seed recipients" do
    test "X-43: creating a tenant queues the setup of its test plane and of no live plane", ctx do
      assert F.jobs(@seeder, ctx.scope, "environment") == [["test"]]
    end

    test "X-43: the setup writes the seven seed recipients with their profiles", ctx do
      seed!(ctx.scope)
      body = get(ctx.token, "/v1/test/seed-recipients")

      assert Enum.map(body["data"], & &1["external_id"]) == @seeds
      assert Enum.all?(body["data"], & &1["set_up"])

      assert %{"email" => "seed_bounced@seed.relay.test", "email_result" => "hard_bounce"} =
               Enum.at(body["data"], 4)

      assert get(ctx.token, "/v1/subscribers/seed_fallback_timezone")["timezone"] == nil
      assert get(ctx.token, "/v1/subscribers/seed_no_device")["timezone"] == "Europe/Istanbul"

      quiet = get(ctx.token, "/v1/subscribers/seed_quiet_hours/preferences")["profile"]
      assert length(quiet["quiet_hours"]) == 14
      assert quiet["quiet_hours_email"] == true

      opted_out = recipient_id(ctx.scope, "seed_opted_out")
      {:ok, consents} = Relay.Preferences.get_consents(ctx.scope, opted_out)

      assert Enum.sort(for c <- consents, do: {c["channel"], c["status"]}) ==
               [{"email", "revoked"}, {"sms", "revoked"}]

      suppressions = get(ctx.token, "/v1/suppressions?channel=email&reason=hard_bounce")["data"]
      assert [%{"reason" => "hard_bounce", "channel" => "email"}] = suppressions

      capped = recipient_id(ctx.scope, "seed_capped")
      category = %{key: "seed", frequency: nil}

      assert %{global: %{count: count}} =
               Relay.Policy.Live.frequency(ctx.scope, category, :marketing, capped, :email)

      assert count >= 12
    end

    test "X-43: setting up again changes nothing and a reset undoes a manual change", ctx do
      seed!(ctx.scope)
      seed!(ctx.scope)

      opted_out = recipient_id(ctx.scope, "seed_opted_out")
      {:ok, consents} = Relay.Preferences.get_consents(ctx.scope, opted_out)
      assert length(consents) == 2

      put = %{"timezone" => "Europe/Berlin"}
      F.body(F.request(:put, "/v1/subscribers/seed_fallback_timezone", ctx.token, put), 200)
      assert get(ctx.token, "/v1/subscribers/seed_fallback_timezone")["timezone"] != nil

      reset = F.request(:post, "/v1/test/seed-recipients/reset", ctx.token)
      assert F.body(reset, 202) == %{"object" => "seed_reset", "status" => "queued"}
      assert length(F.jobs(@seeder, ctx.scope, "environment")) == 2

      seed!(ctx.scope)
      assert get(ctx.token, "/v1/subscribers/seed_fallback_timezone")["timezone"] == nil
    end

    test "X-43 X-25: the live plane has no seed recipients and refuses their addresses", ctx do
      conn = F.request(:get, "/v1/test/seed-recipients", ctx.live_token)
      assert F.body(conn, 403)["code"] == "auth_environment_mismatch"

      conn = F.request(:post, "/v1/test/seed-recipients/reset", ctx.live_token)
      assert F.body(conn, 403)["code"] == "auth_environment_mismatch"

      seed!(ctx.scope)
      assert F.request(:get, "/v1/subscribers/seed_no_consent", ctx.live_token).status == 404

      for seed <- Relay.Channels.seed_recipients() do
        assert Relay.Channels.simulated_address?("email", seed["email"])
        assert Relay.Channels.simulated_address?("sms", seed["phone"])
      end
    end

    test "X-43 X-26: the seed addresses are in the fake provider's table" do
      assert Simulated.result(:email, "seed_bounced@seed.relay.test") == "hard_bounce"
      assert Simulated.result(:email, "seed_capped@seed.relay.test") == "delivered"

      rows = Map.new(Simulated.table(), &{&1["result"], &1["seed_recipients"]})
      assert rows["hard_bounce"] == ["seed_bounced@seed.relay.test"]
      assert "seed_bounced@seed.relay.test" not in rows["delivered"]
      assert "+990555100005" in rows["delivered"]
      assert length(rows["delivered"]) == 13
    end
  end

  describe "X-35 sample workflow" do
    test "X-35: the test plane gets a published sample workflow with inbox and e-mail steps",
         ctx do
      seed!(ctx.scope)

      assert {:ok, {:ok, published}} = Relay.Workflow.resolve_published(ctx.scope, "welcome")
      channels = for step <- published["definition"]["steps"], do: step["channel"]
      assert channels == ["in_app", "email"]
    end
  end

  describe "X-52 test inbox" do
    test "X-52 X-26: a test plane message shows its decision and its rendered output", ctx do
      seed!(ctx.scope)

      data = %{"first_name" => "Ada"}
      event = %{"workflow" => "welcome", "to" => ["seed_bounced"], "data" => data}
      accepted = F.body(F.request(:post, "/v1/events", ctx.token, event), 202)
      [%{"notification_id" => notification}] = accepted["notifications"]
      run_sends(ctx.scope)

      shown = message(ctx.token, notification)
      assert shown["object"] == "test_inbox_message"
      assert shown["workflow"]["key"] == "welcome"
      deliveries = Map.new(shown["deliveries"], &{&1["channel"], &1})

      assert %{"gates" => "stopped", "rule_id" => rule_id, "render" => nil} = deliveries["email"]
      assert is_binary(rule_id)
      assert Enum.any?(deliveries["email"]["decisions"], &(&1["rule_id"] == rule_id))

      inbox = deliveries["in_app"]
      assert inbox["gates"] == "passed"
      assert %{"output" => %{"body" => body}, "digest_only" => nil} = inbox["render"]
      assert body =~ "Ada"
    end

    test "X-52 INV-22: a security subtype message keeps its digest only in the test inbox",
         ctx do
      :ok = F.category!(ctx.token, "login", "security")
      cells = %{"sms" => %{"body" => "Kodunuz {{ order }}"}}
      definition = F.template_definition(cells)
      :ok = F.template!(ctx.scope, "order-shipped", "login", definition: definition)
      opts = [category: "login", message_class: "security", channels: ["sms"]]
      F.workflow!(ctx.scope, ctx.token, "login-code", opts)

      event = %{
        "workflow" => "login-code",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "phone" => "+905551112233"}],
        "data" => %{"order" => "482913"},
        "security_subtype" => "otp_oob",
        "expires_at" => DateTime.to_iso8601(DateTime.add(Relay.Clock.utc_now(), 600))
      }

      accepted = F.body(F.request(:post, "/v1/events", ctx.token, event), 202)
      [%{"notification_id" => notification}] = accepted["notifications"]
      run_sends(ctx.scope)

      [delivery] = message(ctx.token, notification)["deliveries"]
      assert %{"output" => nil, "digest_only" => "security_subtype"} = delivery["render"]
      assert delivery["render"]["content_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "X-52: the live plane has no test inbox", ctx do
      conn = F.request(:get, "/v1/test/inbox", ctx.live_token)
      assert F.body(conn, 403)["code"] == "auth_environment_mismatch"
    end
  end
end
