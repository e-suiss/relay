defmodule RelayWeb.Api.RecurrencesTest do
  use Relay.DataCase, async: false

  alias Relay.Api.Recurrences
  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias Relay.Workflow.RecurrenceStore
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @timer "Relay.Api.Recurrences.Timer"

  setup do
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    token = F.token(scope)
    F.workflow!(scope, token, "reminder")
    %{tenant: tenant, scope: scope, token: token}
  end

  defp subscriber!(token, extra \\ %{}) do
    external_id = "rec-" <> TenantFixture.random()
    body = Map.merge(%{"external_id" => external_id, "email" => "r@example.com"}, extra)
    F.body(F.request(:post, "/v1/subscribers", token, body), 201)
    external_id
  end

  defp rule(overrides) do
    Map.merge(
      %{
        "workflow" => "reminder",
        "rrule" => "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
        "dtstart" => yesterday() <> "T09:00:00",
        "data" => %{"order" => "A-1"}
      },
      overrides
    )
  end

  defp yesterday,
    do: Relay.Clock.utc_now() |> DateTime.to_date() |> Date.add(-1) |> Date.to_iso8601()

  defp create(token, body), do: F.request(:post, "/v1/recurrences", token, body)

  defp created!(token, body), do: F.body(create(token, body), 201)

  defp get!(token, id), do: F.body(F.request(:get, "/v1/recurrences/" <> id, token), 200)

  defp problem(conn, status), do: F.body(conn, status)

  defp pointers(body), do: Enum.map(body["errors"], &{&1["pointer"], &1["code"]})

  defp id(external), do: elem(Relay.ExternalId.decode(external, ["rec"]), 1)

  defp utc(text) do
    {:ok, at, 0} = DateTime.from_iso8601(text)
    at
  end

  defp advance_to!(scope, at) do
    ms = max(DateTime.diff(at, Relay.Clock.business_now(scope), :millisecond), 0) + 1_000
    {:ok, {:advanced, _offset, _now}} = VirtualClock.advance(scope, ms, digest(), actor())
    :ok
  end

  defp digest, do: TenantFixture.digest()
  defp actor, do: TenantFixture.actor()

  defp occurrences(scope, external) do
    {:ok, rows} = Relay.Workflow.recurrence_occurrences(scope, id(external), 100)
    rows
  end

  defp timers(scope, external) do
    Repo.query!(
      "SELECT scheduled_at FROM relay_queue.oban_jobs WHERE worker = $1 AND args->>'recurrence_id' = $2 AND args->>'tenant_id' = $3 ORDER BY id",
      [@timer, Relay.Id.to_string(id(external)), Relay.Scope.tenant_text(scope)]
    ).rows
  end

  describe "WF-48 WF-61 definition" do
    test "WF-48, WF-45: a subscriber rule runs in the subscriber's zone with its first occurrence and timer",
         ctx do
      subscriber = subscriber!(ctx.token, %{"timezone" => "America/New_York"})
      conn = create(ctx.token, rule(%{"subscriber_id" => subscriber}))
      body = F.body(conn, 201)

      assert %{
               "object" => "recurrence",
               "id" => "rec_" <> _,
               "workflow" => %{"key" => "reminder"},
               "subscriber_id" => ^subscriber,
               "topic" => nil,
               "rrule" => "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
               "timezone" => nil,
               "state" => "active",
               "next_occurrence_timezone" => "America/New_York",
               "occurrence_count" => 0,
               "last_occurrence" => nil
             } = body

      refute Map.has_key?(body, "data")
      assert Plug.Conn.get_resp_header(conn, "location") == ["/v1/recurrences/" <> body["id"]]

      next = utc(body["next_occurrence_at"])
      local = DateTime.shift_zone!(next, "America/New_York")
      assert {local.hour, local.minute} == {9, 0}
      assert DateTime.compare(next, Relay.Clock.business_now(ctx.scope)) == :gt

      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id(body["id"]))
      jitter = DateTime.diff(row["fire_at"], row["next_at"], :millisecond)
      assert jitter >= 0 and jitter < 60_000

      assert [[scheduled_at]] = timers(ctx.scope, body["id"])
      expected = Relay.Clock.wall_time(ctx.scope, row["fire_at"])
      assert abs(DateTime.diff(scheduled_at, expected, :millisecond)) < 1_000

      assert get!(ctx.token, body["id"])["id"] == body["id"]
      listed = F.body(F.request(:get, "/v1/recurrences", ctx.token), 200)["data"]
      assert [%{"subscriber_id" => ^subscriber}] = listed
    end

    test "WF-61: a topic rule runs in its own zone, else the tenant default", ctx do
      body = created!(ctx.token, rule(%{"topic" => "proj-1", "timezone" => "Europe/Berlin"}))

      assert %{"topic" => "proj-1", "subscriber_id" => nil, "timezone" => "Europe/Berlin"} = body
      assert body["next_occurrence_timezone"] == "Europe/Berlin"

      default = created!(ctx.token, rule(%{"topic" => "proj-2"}))
      assert default["timezone"] == nil
      assert default["next_occurrence_timezone"] == "Europe/Istanbul"
    end

    test "WF-61: an unsupported RRULE part is a field error that names it", ctx do
      subscriber = subscriber!(ctx.token)
      body = rule(%{"subscriber_id" => subscriber, "rrule" => "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1"})
      problem = problem(create(ctx.token, body), 422)

      assert problem["code"] == "validation_failed"
      assert {"/rrule", "unsupported_value"} in pointers(problem)
      assert Enum.any?(problem["errors"], &String.contains?(&1["detail"], "BYSETPOS"))

      hourly = rule(%{"subscriber_id" => subscriber, "rrule" => "FREQ=HOURLY"})
      problem = problem(create(ctx.token, hourly), 422)
      assert Enum.any?(problem["errors"], &String.contains?(&1["detail"], "FREQ=HOURLY"))
    end

    test "WF-61, WF-45: the request's field rules are checked", ctx do
      subscriber = subscriber!(ctx.token)

      zoned = rule(%{"subscriber_id" => subscriber, "timezone" => "Europe/Berlin"})
      assert {"/timezone", "not_allowed"} in pointers(problem(create(ctx.token, zoned), 422))

      bad_zone = rule(%{"topic" => "t-1", "timezone" => "Mars/Olympus"})

      assert {"/timezone", "invalid_format"} in pointers(
               problem(create(ctx.token, bad_zone), 422)
             )

      far = rule(%{"subscriber_id" => subscriber, "dtstart" => "2040-01-01T09:00:00"})
      assert {"/dtstart", "not_allowed"} in pointers(problem(create(ctx.token, far), 422))

      until =
        rule(%{"subscriber_id" => subscriber, "rrule" => "FREQ=DAILY;UNTIL=20400101T000000Z"})

      assert {"/rrule", "not_allowed"} in pointers(problem(create(ctx.token, until), 422))

      over = rule(%{"subscriber_id" => subscriber, "rrule" => "FREQ=DAILY;COUNT=1"})
      assert {"/rrule", "not_allowed"} in pointers(problem(create(ctx.token, over), 422))

      neither = Map.delete(rule(%{}), "subscriber_id")
      assert {"/subscriber_id", "required"} in pointers(problem(create(ctx.token, neither), 422))

      both = rule(%{"subscriber_id" => subscriber, "topic" => "t-1"})
      assert {"/topic", "not_allowed"} in pointers(problem(create(ctx.token, both), 422))

      data = rule(%{"subscriber_id" => subscriber, "data" => %{}})
      problem = problem(create(ctx.token, data), 422)
      assert Enum.any?(pointers(problem), fn {pointer, _code} -> pointer =~ "/data" end)
    end

    test "WF-48: an unknown workflow or subscriber is not found", ctx do
      subscriber = subscriber!(ctx.token)

      assert problem(create(ctx.token, rule(%{"subscriber_id" => "ghost-1"})), 404)["code"] ==
               "subscriber_not_found"

      unknown = rule(%{"subscriber_id" => subscriber, "workflow" => "missing-flow"})
      assert problem(create(ctx.token, unknown), 404)["code"] == "workflow_not_found"
    end

    test "WF-49, WF-61: the tenant environment's active rule ceiling is enforced", ctx do
      body = created!(ctx.token, rule(%{"subscriber_id" => subscriber!(ctx.token)}))
      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id(body["id"]))

      attrs =
        row
        |> Map.take(~w(workflow_id workflow_key target_kind recipient_id topic_key rrule dtstart
                       timezone data_ct data_key_id next_at next_ordinal next_zone fire_at))
        |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
        |> Map.put(:id, Relay.Id.generate())

      assert {:ok, :limit_reached} =
               Repo.in_scope(ctx.scope, fn _status ->
                 RecurrenceStore.create(attrs, 1, digest(), actor())
               end)

      assert {:ok, :created} =
               Repo.in_scope(ctx.scope, fn _status ->
                 RecurrenceStore.create(attrs, 2, digest(), actor())
               end)

      assert Relay.Limits.fetch!(["recurrence", "max_active_per_environment"]) == 100_000
    end
  end

  describe "WF-49 WF-61 firing" do
    test "WF-49, WF-42: a due occurrence is sent once through the event path with the published version and the rule moves on",
         ctx do
      subscriber = subscriber!(ctx.token)
      body = created!(ctx.token, rule(%{"subscriber_id" => subscriber}))
      id = id(body["id"])
      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id)

      assert :ok = Recurrences.fire(ctx.scope, id)
      assert occurrences(ctx.scope, body["id"]) == []

      advance_to!(ctx.scope, row["fire_at"])
      assert :ok = Recurrences.fire(ctx.scope, id)
      assert :ok = Recurrences.fire(ctx.scope, id)

      assert [%{"outcome" => "sent", "event_id" => <<_::128>> = event_id} = sent] =
               occurrences(ctx.scope, body["id"])

      assert DateTime.compare(sent["occurrence_at"], row["next_at"]) == :eq

      event =
        F.body(
          F.request(:get, "/v1/events/" <> Relay.ExternalId.encode("evt", event_id), ctx.token),
          200
        )

      assert event["workflow"] == %{"key" => "reminder", "version" => 1}

      after_fire = get!(ctx.token, body["id"])
      assert after_fire["occurrence_count"] == 1
      assert after_fire["last_occurrence"]["outcome"] == "sent"
      assert after_fire["last_occurrence"]["event_id"] == Relay.ExternalId.encode("evt", event_id)

      assert DateTime.diff(utc(after_fire["next_occurrence_at"]), row["next_at"], :second) ==
               86_400

      assert length(timers(ctx.scope, body["id"])) == 2
    end

    test "WF-61, L-43: after an outage only the last due occurrence is sent and only within PT1H",
         ctx do
      body = created!(ctx.token, rule(%{"subscriber_id" => subscriber!(ctx.token)}))
      id = id(body["id"])
      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id)

      advance_to!(ctx.scope, DateTime.add(row["next_at"], 2 * 86_400 + 7_200, :second))
      assert :ok = Recurrences.run_due(ctx.scope)

      recorded = occurrences(ctx.scope, body["id"])
      assert Enum.map(recorded, & &1["outcome"]) == ~w(missed missed missed)
      assert Enum.all?(recorded, &(&1["rule_id"] == "recurrence.missed"))

      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id)
      assert row["occurrence_count"] == 3

      advance_to!(ctx.scope, DateTime.add(row["next_at"], 86_400 + 1_800, :second))
      assert :ok = Recurrences.fire(ctx.scope, id)

      assert ~w(missed missed missed missed sent) ==
               Enum.map(occurrences(ctx.scope, body["id"]), & &1["outcome"])
    end

    test "WF-61: a rule with COUNT completes after its last occurrence", ctx do
      body =
        created!(
          ctx.token,
          rule(%{"subscriber_id" => subscriber!(ctx.token), "rrule" => "FREQ=DAILY;COUNT=20"})
        )

      id = id(body["id"])
      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id)
      assert row["next_ordinal"] >= 1

      advance_to!(ctx.scope, DateTime.add(row["next_at"], 40 * 86_400, :second))
      assert :ok = Recurrences.fire(ctx.scope, id)

      done = get!(ctx.token, body["id"])
      assert done["state"] == "completed"
      assert done["next_occurrence_at"] == nil
      assert done["occurrence_count"] == 21 - row["next_ordinal"]
      assert done["completed_at"] != nil
    end

    test "WF-48: a topic rule's occurrence is recorded skipped until topic fan-out exists", ctx do
      body = created!(ctx.token, rule(%{"topic" => "proj-9"}))
      {:ok, row} = Relay.Workflow.get_recurrence(ctx.scope, id(body["id"]))

      advance_to!(ctx.scope, row["fire_at"])
      assert :ok = Recurrences.fire(ctx.scope, id(body["id"]))

      assert [%{"outcome" => "skipped", "rule_id" => "recurrence.topic_unavailable"}] =
               occurrences(ctx.scope, body["id"])

      assert get!(ctx.token, body["id"])["state"] == "active"
    end

    test "WF-49: a cancelled rule sends nothing more and cannot be cancelled again", ctx do
      body = created!(ctx.token, rule(%{"subscriber_id" => subscriber!(ctx.token)}))
      path = "/v1/recurrences/" <> body["id"] <> "/cancel"

      cancelled = F.body(F.request(:post, path, ctx.token), 200)

      assert %{"state" => "cancelled", "cancel_reason" => "request", "next_occurrence_at" => nil} =
               cancelled

      assert problem(F.request(:post, path, ctx.token), 409)["code"] == "recurrence_closed"

      advance_to!(
        ctx.scope,
        DateTime.add(Relay.Clock.business_now(ctx.scope), 3 * 86_400, :second)
      )

      assert :ok = Recurrences.fire(ctx.scope, id(body["id"]))
      assert occurrences(ctx.scope, body["id"]) == []

      missing = "/v1/recurrences/rec_01j9zq3k4m5n6p7q8r9s0t1v2w"
      assert problem(F.request(:get, missing, ctx.token), 404)["code"] == "recurrence_not_found"
    end
  end
end
