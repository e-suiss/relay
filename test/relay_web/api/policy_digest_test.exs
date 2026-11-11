defmodule RelayWeb.Api.PolicyDigestTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @zone "Europe/Istanbul"
  @days ~w(mon tue wed thu fri sat sun)
  @profile "SELECT * FROM relay_fn.preference_profile_put($1, $2, '[]', NULL, false, '{}', 'subscriber', NULL)"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{scope: scope, token: F.token(scope)}
  end

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp category!(token, key, class, extra \\ %{}) do
    body = Map.merge(%{"key" => key, "name" => key, "message_class" => class}, extra)
    F.body(F.request(:post, "/v1/categories", token, body), 201)
  end

  defp workflow!(ctx, key, category, class, channels) do
    opts = [category: category, message_class: class, channels: channels]
    F.workflow!(ctx.scope, ctx.token, key, opts)
  end

  defp subscriber!(token) do
    external_id = "user-" <> TenantFixture.random()
    body = %{"external_id" => external_id, "email" => "ayse@example.com", "timezone" => @zone}
    F.body(F.request(:post, "/v1/subscribers", token, body), 201)

    device = %{
      "platform" => "fcm",
      "token" => "fcm:" <> TenantFixture.random() <> TenantFixture.random(),
      "app" => "com.example.shop",
      "permission" => "granted"
    }

    F.body(F.request(:post, "/v1/subscribers/#{external_id}/devices", token, device), 201)
    external_id
  end

  defp recipient_id(scope, external_id) do
    {:ok, %{"_id" => id}} = Relay.Subscribers.fetch(scope, external_id)
    id
  end

  defp quiet!(scope, external_id) do
    now = DateTime.shift_zone!(Relay.Clock.business_now(scope), @zone)
    from = DateTime.add(now, -3_600)
    to = DateTime.add(now, 7_200)
    day = Enum.at(@days, Date.day_of_week(from) - 1)
    range = %{"day" => day, "start" => hhmm(from), "end" => hhmm(to)}
    [[result, _version]] = sql!(scope, @profile, [recipient_id(scope, external_id), [range]])
    assert result in ["created", "updated"]
  end

  defp hhmm(at), do: at |> DateTime.to_time() |> Time.to_iso8601() |> binary_part(0, 5)

  defp delivery!(token, workflow, to) do
    body = %{"workflow" => workflow, "to" => [to], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, token), 200)["data"]
    delivery
  end

  defp internal(%{"id" => id}) do
    {:ok, delivery_id} = Relay.ExternalId.decode(id, ["dlv"])
    delivery_id
  end

  defp decision(scope, delivery) do
    sql = "SELECT decision, decision_rule_id, deferred_until FROM relay.deliveries WHERE id = $1"
    [row] = sql!(scope, sql, [internal(delivery)])
    row
  end

  defp advance_past!(scope, at) do
    ms = DateTime.diff(at, Relay.Clock.business_now(scope), :millisecond) + 60_000

    digest = TenantFixture.digest()
    actor = TenantFixture.actor()
    {:ok, {:advanced, _offset, _now}} = VirtualClock.advance(scope, ms, digest, actor)
  end

  defp render(scope, delivery) do
    {:ok, render} =
      Repo.in_scope(scope, fn _status -> Relay.Workflow.digest_render(internal(delivery)) end)

    render
  end

  describe "PC-46 morning burst" do
    test "PC-46: social pushes held back by quiet hours share one window and go as one digest",
         ctx do
      category!(ctx.token, "friends", "social")
      workflow!(ctx, "friend-joined", "friends", "social", ["push"])
      external_id = subscriber!(ctx.token)
      quiet!(ctx.scope, external_id)

      held = for _ <- 1..3, do: delivery!(ctx.token, "friend-joined", external_id)
      [first | rest] = held

      for delivery <- held do
        assert %{"status" => "queued", "rule_id" => "digest.quiet_hours"} = delivery
        assert F.delivery_jobs(delivery["id"]) == []
      end

      untils = for delivery <- held, do: List.last(decision(ctx.scope, delivery))
      assert [%DateTime{} = until] = Enum.uniq(untils)

      advance_past!(ctx.scope, until)
      assert :ok = Relay.Workflow.run_due_digests(ctx.scope)

      assert [_job] = F.delivery_jobs(first["id"])

      for delivery <- rest do
        assert ["skip", "digest.folded", nil] = decision(ctx.scope, delivery)
      end

      assert %{"total_activities" => 3, "window_activities" => 3} = render(ctx.scope, first)
      assert render(ctx.scope, hd(rest)) == nil
    end

    test "PC-46: an operational push held back by quiet hours keeps its own deferral", ctx do
      category!(ctx.token, "ops", "operational")
      workflow!(ctx, "maintenance", "ops", "operational", ["push"])
      external_id = subscriber!(ctx.token)
      quiet!(ctx.scope, external_id)

      delivery = delivery!(ctx.token, "maintenance", external_id)
      assert %{"status" => "queued", "rule_id" => "quiet_hours.deferred"} = delivery
      assert [_job] = F.delivery_jobs(delivery["id"])
    end
  end

  describe "WF-30 density threshold" do
    test "WF-30: past the category's density threshold the next deliveries wait in one digest",
         ctx do
      density = %{"limit" => 2, "window" => "PT10M"}
      created = category!(ctx.token, "friends", "social", %{"density" => density})
      assert created["density"] == Map.put(density, "per", "recipient")
      workflow!(ctx, "friend-joined", "friends", "social", ["push"])
      external_id = subscriber!(ctx.token)

      [a, b, c, d] = for _ <- 1..4, do: delivery!(ctx.token, "friend-joined", external_id)

      assert ["send", nil, nil] = decision(ctx.scope, a)
      assert ["send", nil, nil] = decision(ctx.scope, b)
      assert ["defer", "digest.density", %DateTime{} = until] = decision(ctx.scope, c)
      assert ["defer", "digest.density", ^until] = decision(ctx.scope, d)
      assert F.delivery_jobs(c["id"]) == []

      advance_past!(ctx.scope, until)
      assert :ok = Relay.Workflow.run_due_digests(ctx.scope)

      assert [_job] = F.delivery_jobs(c["id"])
      assert ["skip", "digest.folded", nil] = decision(ctx.scope, d)
      assert %{"total_activities" => 2} = render(ctx.scope, c)
    end
  end
end
