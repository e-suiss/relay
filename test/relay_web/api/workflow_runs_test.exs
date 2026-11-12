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

  defp inbox(key),
    do: %{"type" => "channel", "key" => key, "channel" => "in_app", "template" => "order-shipped"}

  defp workflow!(ctx, key, steps, extra \\ %{}, templates \\ []) do
    definition = F.definition() |> Map.put("steps", steps) |> Map.merge(extra)
    :ok = F.category_of!(ctx.token, definition)

    for template <- ["order-shipped" | templates],
        do: :ok = F.template!(ctx.scope, template, definition["category"])

    created =
      F.request(:post, "/v1/workflows", ctx.token, %{"key" => key, "definition" => definition})

    assert created.status == 201, created.resp_body
    F.publish!(ctx.scope, ctx.token, key)
  end

  defp send!(ctx, key, data \\ %{"order" => "A-1"}, to \\ nil) do
    body = %{
      "workflow" => key,
      "to" => [%{"id" => to || "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
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

  defp wait_step,
    do: %{
      "type" => "wait_for_event",
      "key" => "reply",
      "event_type" => "ticket.replied",
      "correlation_key" => "order-{{data.order}}",
      "timeout" => "PT1H"
    }

  defp offer(ctx, run, key),
    do:
      Relay.Agents.offer_event(ctx.scope, %{
        event_type: "ticket.replied",
        correlation_key: key,
        waiter_kind: :subscriber,
        waiter_ref: run["recipient_id"],
        payload_digest: :crypto.hash(:sha256, key)
      })

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

    test "WF-43 WF-63: a delay is a waiting row with one timer and a reminder on the same channel opens when it wakes",
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
      assert {:ok, :completed} = Relay.Workflow.wake(ctx.scope, run["id"])

      channels = ctx |> deliveries(notification) |> Enum.map(& &1["channel"]) |> Enum.sort()
      assert channels == ["email", "email"]

      assert {:ok, :final} = Relay.Workflow.wake(ctx.scope, run["id"], true)
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

    test "WF-32: an event over the throttle limit ends its run skipped with throttle.limited",
         ctx do
      throttle = %{
        "type" => "throttle",
        "key" => "limit",
        "throttle_key" => "order:{{data.order}}",
        "limit" => 1,
        "window" => "PT1H"
      }

      workflow!(ctx, "throttled", [throttle, mail("mail")])
      {first, first_id} = send!(ctx, "throttled")
      {second, second_id} = send!(ctx, "throttled")

      assert [%{"channel" => "email"}] = deliveries(ctx, first)
      assert %{"state" => "completed", "outcome" => "completed"} = run!(ctx, first_id)

      assert deliveries(ctx, second) == []

      assert %{"outcome" => "stopped", "rule_id" => "throttle.limited", "step_results" => results} =
               run!(ctx, second_id)

      assert results["limit"]["throttled"] == true
    end

    test "WF-13 WF-15: a fallback route moves on when its first channel is skipped", ctx do
      route = %{"single" => ["sms", "email"]}

      step = %{
        "type" => "channel",
        "key" => "routed",
        "route" => route,
        "template" => "order-shipped"
      }

      workflow!(ctx, "fallback", [step])
      {notification, id} = send!(ctx, "fallback")

      channels = ctx |> deliveries(notification) |> Enum.map(&{&1["channel"], &1["status"]})
      assert {"sms", "skipped"} in channels
      assert {"email", "queued"} in channels

      assert %{"step_cursor" => %{"routes" => %{"routed" => route_state}}} = run!(ctx, id)
      assert Map.keys(route_state["leaves"]) |> Enum.sort() == ["/single/0", "/single/1"]
    end

    test "WF-10: a condition reads a declared recipient attribute", ctx do
      check = %{
        "type" => "condition",
        "key" => "check",
        "branches" => [
          %{
            "when" => %{"eq" => [%{"var" => "recipient.plan"}, "gold"]},
            "steps" => [mail("gold")]
          }
        ],
        "else" => [inbox("other")]
      }

      workflow!(ctx, "attributed", [check], %{"recipient_attributes" => %{"plan" => "string"}})

      body = fn plan ->
        %{
          "workflow" => "attributed",
          "to" => [
            %{
              "id" => "user-" <> TenantFixture.random(),
              "email" => "ayse@example.com",
              "attributes" => %{"plan" => plan}
            }
          ],
          "data" => %{"order" => "A-1"}
        }
      end

      for {plan, channel} <- [{"gold", "email"}, {"silver", "in_app"}] do
        accepted = F.body(F.request(:post, "/v1/events", ctx.token, body.(plan)), 202)
        [%{"notification_id" => notification}] = accepted["notifications"]
        assert [%{"channel" => ^channel}] = deliveries(ctx, notification)
      end
    end

    test "WF-27: a digest anchor parks, a later event folds, and the fired window resumes the anchor with the digest template",
         ctx do
      digest = %{
        "type" => "digest",
        "key" => "batch",
        "digest_key" => "order:{{data.order}}",
        "mode" => "fixed",
        "max_wait" => "PT1H"
      }

      reminder = Map.put(mail("mail"), "digest_template", "order-shipped")
      definition = F.definition(message_class: "social") |> Map.put("steps", [digest, reminder])
      :ok = F.category_of!(ctx.token, definition)
      :ok = F.template!(ctx.scope, "order-shipped", definition["category"])
      body = %{"key" => "digested", "definition" => definition}
      assert F.request(:post, "/v1/workflows", ctx.token, body).status == 201
      F.publish!(ctx.scope, ctx.token, "digested")

      recipient = "user-" <> TenantFixture.random()

      event = %{
        "workflow" => "digested",
        "to" => [%{"id" => recipient, "email" => "ayse@example.com"}],
        "data" => %{"order" => "A-1"}
      }

      [first, second] =
        for _n <- 1..2 do
          accepted = F.body(F.request(:post, "/v1/events", ctx.token, event), 202)
          [%{"notification_id" => notification}] = accepted["notifications"]
          {:ok, id} = Relay.ExternalId.decode(notification, ["ntf"])
          {notification, id}
        end

      anchor = run!(ctx, elem(first, 1))
      assert anchor["state"] == "running"
      assert anchor["step_cursor"]["parked"] == "batch"
      assert %{"state" => "completed", "step_results" => folded} = run!(ctx, elem(second, 1))
      assert folded["batch"]["outcome"] == "folded"
      assert deliveries(ctx, elem(first, 0)) == []

      advance!(ctx, @hour + 60_000)
      {:ok, window_id} = Relay.Id.parse(anchor["step_results"]["batch"]["window_id"])
      assert {:ok, _closed} = Relay.Workflow.digest_fire(ctx.scope, window_id)
      assert {:ok, :completed} = Relay.Workflow.wake(ctx.scope, anchor["id"], true)

      assert [%{"id" => delivery}] = deliveries(ctx, elem(first, 0))
      {:ok, delivery_id} = Relay.ExternalId.decode(delivery, ["dlv"])

      assert {:ok, %{"total_activities" => 2}} =
               Repo.in_scope(ctx.scope, fn _status ->
                 Relay.Workflow.digest_render(delivery_id)
               end)
    end

    test "WF-12: an event wait parks the run until a matching event resumes it", ctx do
      workflow!(ctx, "waits", [wait_step(), mail("after")])
      {notification, id} = send!(ctx, "waits")

      assert deliveries(ctx, notification) == []
      run = run!(ctx, id)
      assert run["step_cursor"]["parked"] == "reply"
      assert %{"outcome" => "waiting", "waitpoint_id" => waitpoint} = run["step_results"]["reply"]

      {:ok, waitpoint_id} = Relay.Id.parse(waitpoint)

      assert {:ok, %{state: "open", kind: "event", waiter_kind: "subscriber"}} =
               Relay.Agents.get_waitpoint(ctx.scope, waitpoint_id)

      assert {:ok, %{result: :buffered}} = offer(ctx, run, "order-B-2")

      assert {:ok, %{result: :matched, resolved: [{^waitpoint_id, :resolved}]}} =
               offer(ctx, run, "order-A-1")

      assert {:ok, :completed} = Relay.Workflow.wake(ctx.scope, run["id"], true)
      assert [%{"channel" => "email"}] = deliveries(ctx, notification)
      assert %{"matched" => true, "outcome" => "matched"} = run!(ctx, id)["step_results"]["reply"]
    end

    test "WF-12 OP-24: erasing the subscriber cancels its open event wait", ctx do
      RelayTest.TenantFixture.retention_periods!()
      workflow!(ctx, "erased-waits", [wait_step(), mail("after")])
      {_notification, id} = send!(ctx, "erased-waits")
      run = run!(ctx, id)
      {:ok, waitpoint_id} = Relay.Id.parse(run["step_results"]["reply"]["waitpoint_id"])

      actor = %Relay.Actor{
        kind: :operator,
        ref: "op-1",
        on_behalf_of_ref: "op-1",
        access_record_ref: "acc-rec-1"
      }

      assert {:ok, :erased, _cancelled} =
               Relay.Keys.Erasure.erase_subject(ctx.scope, run["recipient_id"], "dsr-wait", actor)

      assert {:ok, %{state: "cancelled"}} = Relay.Agents.get_waitpoint(ctx.scope, waitpoint_id)
    end

    test "WF-12: a wait that times out runs on_timeout and goes on", ctx do
      wait = Map.put(wait_step(), "on_timeout", [inbox("nudge")])
      workflow!(ctx, "nudges", [wait, mail("after")])
      {notification, id} = send!(ctx, "nudges")
      run = run!(ctx, id)

      advance!(ctx, @hour + 60_000)
      assert :ok = Relay.Agents.run_due(ctx.scope)

      assert %{"step_results" => %{"reply" => %{"timed_out" => true}}} = run!(ctx, id)
      assert {:ok, :completed} = Relay.Workflow.wake(ctx.scope, run["id"], true)

      channels = ctx |> deliveries(notification) |> Enum.map(& &1["channel"]) |> Enum.sort()
      assert channels == ["email", "in_app"]
    end

    test "WF-12 AG-13: an event that arrived before the wait opened is buffered and resolves it at once",
         ctx do
      user = "user-" <> TenantFixture.random()
      workflow!(ctx, "first", [mail("mail")])
      {_notification, first} = send!(ctx, "first", %{"order" => "A-1"}, user)
      earlier = run!(ctx, first)

      assert {:ok, %{result: :buffered}} = offer(ctx, earlier, "order-A-1")

      workflow!(ctx, "waits-late", [wait_step(), mail("after")])
      {notification, id} = send!(ctx, "waits-late", %{"order" => "A-1"}, user)

      assert [%{"channel" => "email"}] = deliveries(ctx, notification)

      assert %{"state" => "completed", "step_results" => %{"reply" => %{"matched" => true}}} =
               run!(ctx, id)
    end

    test "WF-50: a variant step sends the frozen variant's template and the variant report counts it",
         ctx do
      step =
        Map.put(mail("mail"), "variants", [
          %{"key" => "control", "weight" => 1, "template" => "order-shipped"},
          %{"key" => "bold", "weight" => 1, "template" => "order-shipped-bold"}
        ])

      workflow!(ctx, "split", [step], %{}, ["order-shipped-bold"])
      {notification, id} = send!(ctx, "split")
      run = run!(ctx, id)

      assert [%{"channel" => "email"}] = deliveries(ctx, notification)
      variant = run["plan"]["variants"]["mail"]["key"]
      assert variant in ["control", "bold"]
      assert run["step_results"]["mail"]["variant"] == variant

      today = DateTime.to_date(Relay.Clock.utc_now())
      assert {:ok, %{variants: 1}} = Relay.Delivery.recompute_report_day(ctx.scope, today)
      {:ok, rows} = Relay.Delivery.report(ctx.scope, :variants, today, Date.add(today, 1))

      assert [
               %{
                 "workflow_key" => "split",
                 "step_key" => "mail",
                 "variant" => ^variant,
                 "channel" => "email",
                 "accepted" => 1
               }
             ] = rows
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
