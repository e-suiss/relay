defmodule RelayWeb.Api.WorkflowRunsTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @hour 3_600_000

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    %{scope: scope, token: F.token(scope)}
  end

  defp mail(key),
    do: %{"type" => "channel", "key" => key, "channel" => "email", "template" => "order-shipped"}

  defp workflow!(ctx, key, steps, extra \\ %{}) do
    definition = F.definition() |> Map.put("steps", steps) |> Map.merge(extra)
    :ok = F.category_of!(ctx.token, definition)
    :ok = F.template!(ctx.scope, "order-shipped", definition["category"])

    created =
      F.request(:post, "/v1/workflows", ctx.token, %{"key" => key, "definition" => definition})

    assert created.status == 201, created.resp_body
    F.publish!(ctx.scope, ctx.token, key)
  end

  defp send!(ctx, key, data \\ %{"order" => "A-1"}) do
    body = %{
      "workflow" => key,
      "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
      "data" => data
    }

    accepted = F.body(F.request(:post, "/v1/events", ctx.token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    {:ok, id} = Relay.ExternalId.decode(notification, ["ntf"])
    {notification, id}
  end

  defp deliveries(ctx, notification),
    do:
      F.body(F.request(:get, "/v1/notifications/#{notification}/deliveries", ctx.token), 200)[
        "data"
      ]

  defp run!(ctx, id) do
    {:ok, run} = Relay.Workflow.run(ctx.scope, id)
    run
  end

  defp timers(ctx) do
    Repo.query!(
      "SELECT args->>'run_id' FROM relay_queue.oban_jobs WHERE worker = $1 AND args->>'tenant_id' = $2",
      ["Relay.Workflow.RunTimer", Relay.Id.to_string(ctx.scope.tenant_id)]
    ).rows
  end

  defp advance!(ctx, ms) do
    assert {:ok, {:advanced, _, _}} =
             VirtualClock.advance(ctx.scope, ms, TenantFixture.digest(), TenantFixture.actor())
  end

  describe "WF-59 (5) workflow runs" do
    test "WF-59: a single channel step opens its delivery at acceptance and the run completes",
         ctx do
      workflow!(ctx, "single", [mail("mail")])
      {notification, id} = send!(ctx, "single")

      assert [%{"channel" => "email", "status" => "queued"}] = deliveries(ctx, notification)
      assert %{"state" => "completed", "outcome" => "completed"} = run!(ctx, id)
    end

    test "WF-43: a delay is a waiting row with one timer and the later step opens when it wakes",
         ctx do
      workflow!(ctx, "later", [
        mail("first"),
        %{"type" => "delay", "key" => "wait", "duration" => "PT1H"},
        mail("second")
      ])

      {notification, id} = send!(ctx, "later")

      assert [%{"channel" => "email"}] = deliveries(ctx, notification)
      run = run!(ctx, id)
      assert run["state"] == "waiting"
      assert [[run_id]] = timers(ctx)
      assert run_id == Relay.Id.to_string(run["id"])

      assert {:ok, :not_due} = Relay.Workflow.wake(ctx.scope, run["id"])

      advance!(ctx, @hour + 60_000)
      assert :ok = Relay.Workflow.run_due(ctx.scope)

      assert [_, _] = deliveries(ctx, notification)
      assert %{"state" => "completed", "step_results" => results} = run!(ctx, id)
      assert [_] = results["second"]["deliveries"]
      assert results["wait"]["outcome"] == "waited"
    end

    test "WF-6: a waiting run finishes on the version it started on", ctx do
      steps = [%{"type" => "delay", "key" => "wait", "duration" => "PT1H"}, mail("second")]
      workflow!(ctx, "pinned", steps)
      {_notification, id} = send!(ctx, "pinned")
      started = run!(ctx, id)

      current = F.request(:get, "/v1/workflows/pinned", ctx.token)
      [etag] = Plug.Conn.get_resp_header(current, "etag")
      draft = Map.put(F.definition(), "steps", [mail("other")])

      replaced =
        F.request(:put, "/v1/workflows/pinned", ctx.token, %{"definition" => draft}, [
          {"if-match", etag}
        ])

      assert replaced.status == 200, replaced.resp_body
      F.publish!(ctx.scope, ctx.token, "pinned")

      advance!(ctx, 2 * @hour)
      assert :ok = Relay.Workflow.run_due(ctx.scope)

      finished = run!(ctx, id)
      assert finished["workflow_version_id"] == started["workflow_version_id"]
      assert Map.has_key?(finished["step_results"], "second")
      refute Map.has_key?(finished["step_results"], "other")
    end

    test "WF-10: a condition on the event data chooses the branch that opens", ctx do
      check = %{
        "type" => "condition",
        "key" => "check",
        "branches" => [
          %{"when" => %{"eq" => [%{"var" => "data.order"}, "A-1"]}, "steps" => [mail("yes")]}
        ],
        "else" => [
          %{
            "type" => "channel",
            "key" => "no",
            "channel" => "in_app",
            "template" => "order-shipped"
          }
        ]
      }

      workflow!(ctx, "branchy", [check])

      {notification, _id} = send!(ctx, "branchy")
      assert [%{"channel" => "email"}] = deliveries(ctx, notification)

      {other, _id} = send!(ctx, "branchy", %{"order" => "B-2"})
      assert [%{"channel" => "in_app"}] = deliveries(ctx, other)
    end

    test "WF-8: a step type that is not executable yet is recorded with its rule, not skipped silently",
         ctx do
      throttle = %{
        "type" => "throttle",
        "key" => "limit",
        "throttle_key" => "{{data.order}}",
        "limit" => 1,
        "window" => "PT1H"
      }

      workflow!(ctx, "throttled", [throttle, mail("mail")])
      {notification, id} = send!(ctx, "throttled")

      assert [%{"channel" => "email"}] = deliveries(ctx, notification)

      assert %{"outcome" => "skipped", "rule_id" => "workflow_run.step_unavailable"} =
               run!(ctx, id)["step_results"]["limit"]
    end

    test "API-57: cancelling the notification cancels its waiting run", ctx do
      workflow!(ctx, "cancelled", [
        %{"type" => "delay", "key" => "wait", "duration" => "PT1H"},
        mail("mail")
      ])

      {notification, id} = send!(ctx, "cancelled")

      cancel = F.request(:post, "/v1/notifications/#{notification}/cancel", ctx.token, %{})
      assert cancel.status == 200, cancel.resp_body

      assert %{"state" => "cancelled", "rule_id" => "cancel.request"} = run!(ctx, id)

      advance!(ctx, 2 * @hour)
      assert :ok = Relay.Workflow.run_due(ctx.scope)
      assert deliveries(ctx, notification) == []
    end
  end

  describe "WF-6 WF-4 workflow management" do
    test "WF-6: a published version exports as a Mermaid flowchart", ctx do
      workflow!(ctx, "charted", [
        mail("first"),
        %{"type" => "delay", "key" => "wait", "duration" => "PT1H"},
        mail("second")
      ])

      conn = F.request(:get, "/v1/workflows/charted/versions/1/mermaid", ctx.token)
      assert conn.status == 200
      assert ["text/plain" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "flowchart TD"
      assert conn.resp_body =~ "s_first --> s_wait"

      missing = F.request(:get, "/v1/workflows/charted/versions/9/mermaid", ctx.token)
      assert missing.status == 404
    end

    test "WF-4: the manager is changed explicitly and a panel write to a code-managed workflow changes only its controls",
         ctx do
      steps = [%{"type" => "delay", "key" => "wait", "duration" => "PT1H"}, mail("mail")]
      workflow!(ctx, "coded", steps, %{"controls" => ["/steps/0/duration"]})

      current = F.request(:get, "/v1/workflows/coded", ctx.token)
      [etag] = Plug.Conn.get_resp_header(current, "etag")

      changed =
        F.body(
          F.request(:post, "/v1/workflows/coded/manager", ctx.token, %{"managed_by" => "code"}, [
            {"if-match", etag}
          ]),
          200
        )

      assert changed["managed_by"] == "code"

      {:ok, operator} = Relay.Actor.new(:operator, "operator-1", "operator-1")

      base =
        F.definition() |> Map.put("steps", steps) |> Map.put("controls", ["/steps/0/duration"])

      tuned = put_in(base, ["steps", Access.at(0), "duration"], "PT2H")
      restructured = Map.put(base, "steps", [mail("mail")])

      {:ok, results} =
        Repo.in_scope(ctx.scope, fn _status ->
          {:ok, first} =
            Relay.Workflow.replace_draft(ctx.scope, "coded", restructured, nil, operator)

          {:ok, second} = Relay.Workflow.replace_draft(ctx.scope, "coded", tuned, nil, operator)
          {first, second}
        end)

      assert {{:managed_by_code, [_ | _]}, {:replaced, _version}} = results
    end
  end
end
