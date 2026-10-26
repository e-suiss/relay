defmodule Relay.Delivery.RetrySingleLayerTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.DeliveryFixture
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    Map.put(DeliveryFixture.sendable!(), :parameters, DeliveryFixture.parameters(1))
  end

  defp jobs_for(delivery_id) do
    Repo.query!(
      "SELECT args, priority, scheduled_at FROM relay_queue.oban_jobs WHERE args->>'delivery_id' = $1 AND args ? 'attempt_no'",
      [Relay.Id.to_string(delivery_id)]
    ).rows
  end

  defp send_once(counter) do
    Relay.Channels.http_request(
      url: "http://provider.invalid/send",
      method: :post,
      retry: :transient,
      max_retries: 5,
      plug: fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end
    )
  end

  test "T-26, INV-13: a provider 503 becomes exactly one new job; the HTTP client never retries",
       ctx do
    counter = :counters.new(1, [])
    key = "pik-" <> TenantFixture.random()
    attempt = DeliveryFixture.started_attempt!(ctx.scope, ctx.delivery_id, key)

    assert {:ok, %Req.Response{status: 503}} = send_once(counter)
    assert :counters.get(counter, 1) == 1

    failure =
      DeliveryFixture.failure(ctx.delivery_id, attempt, ctx.parameters,
        channel: "push",
        provider: "fcm",
        condition: "server_error",
        raw_code: "503"
      )

    assert {:ok, {:applied, {:retry, at, 2, 2}, :scheduled}} =
             Relay.Delivery.fail_attempt(ctx.scope, failure)

    assert [[args, 2, scheduled_at]] = jobs_for(ctx.delivery_id)
    assert args["attempt_no"] == 2
    assert args["provider_idempotency_key"] == key
    assert NaiveDateTime.compare(scheduled_at, DateTime.to_naive(at)) == :eq

    assert {:ok, {:opened, 2}} =
             Relay.Delivery.open_attempt(ctx.scope, %{
               id: Relay.Id.generate(),
               delivery_id: ctx.delivery_id,
               provider_idempotency_key: args["provider_idempotency_key"]
             })
  end

  test "T-26: the retry is planned from the database clock and the delivery stays open", ctx do
    attempt = DeliveryFixture.started_attempt!(ctx.scope, ctx.delivery_id)
    failure = DeliveryFixture.failure(ctx.delivery_id, attempt, ctx.parameters)

    assert {:ok, {:applied, {:retry, at, 2, 2}, :scheduled}} =
             Relay.Delivery.fail_attempt(ctx.scope, failure)

    wait = DateTime.diff(at, DateTime.utc_now(), :millisecond)
    assert wait > 0 and wait <= 1_260_000
    assert {:ok, %{"failure_kind" => nil}} = Relay.Delivery.delivery(ctx.scope, ctx.delivery_id)
  end

  test "T-26: a duplicate finish plans nothing", ctx do
    attempt = DeliveryFixture.started_attempt!(ctx.scope, ctx.delivery_id)
    failure = DeliveryFixture.failure(ctx.delivery_id, attempt, ctx.parameters)
    {:ok, {:applied, _, _}} = Relay.Delivery.fail_attempt(ctx.scope, failure)

    assert {:ok, {:duplicate_ignored, nil, nil}} =
             Relay.Delivery.fail_attempt(ctx.scope, %{failure | event_id: Relay.Id.generate()})

    assert length(jobs_for(ctx.delivery_id)) == 1
  end

  test "CH-12: a retry past expires_at expires the delivery", ctx do
    expiring =
      DeliveryFixture.sendable!(
        notification: [expires_at: DateTime.add(DateTime.utc_now(), 2, :second)]
      )

    attempt = DeliveryFixture.started_attempt!(expiring.scope, expiring.delivery_id)

    failure =
      DeliveryFixture.failure(expiring.delivery_id, attempt, ctx.parameters,
        expires_at: DateTime.add(DateTime.utc_now(), 2, :second)
      )

    assert {:ok, {:applied, {:expire, "retry.expires_at"}, :expired}} =
             Relay.Delivery.fail_attempt(expiring.scope, failure)

    assert {:ok, %{"failure_kind" => "expired", "failure_rule_id" => "retry.expires_at"}} =
             Relay.Delivery.delivery(expiring.scope, expiring.delivery_id)

    assert jobs_for(expiring.delivery_id) == []
  end

  test "CH-70: a failure without a backoff row goes to the dead letters and raises the alarm",
       ctx do
    parent = self()
    handler = "missing-row-" <> TenantFixture.random()

    :telemetry.attach(
      handler,
      [:relay, :channel_parameters, :missing],
      fn _, _, meta, _ ->
        send(parent, {:missing, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    attempt = DeliveryFixture.started_attempt!(ctx.scope, ctx.delivery_id)

    failure =
      DeliveryFixture.failure(ctx.delivery_id, attempt, ctx.parameters,
        failure_class: "quota",
        condition: nil
      )

    {result, log} =
      ExUnit.CaptureLog.with_log(fn -> Relay.Delivery.fail_attempt(ctx.scope, failure) end)

    assert {:ok,
            {:applied, {:dead_letter, :exhausted, "channel_parameters.missing"}, {:recorded, _}}} =
             result

    assert log =~ "no channel_parameters backoff row"
    assert_receive {:missing, %{channel: "email", failure_class: "quota"}}

    assert {:ok,
            [
              %{"entry_rule_id" => "channel_parameters.missing", "dlq_class" => "exhausted"} =
                letter
            ]} =
             Relay.Delivery.list_dead_letters(ctx.scope)

    assert letter["channel_parameters_version_id"] == ctx.parameters.version_id
  end

  test "INV-14, T-29: a policy failure fails the delivery without a dead letter", ctx do
    attempt = DeliveryFixture.started_attempt!(ctx.scope, ctx.delivery_id)

    failure =
      DeliveryFixture.failure(ctx.delivery_id, attempt, ctx.parameters,
        failure_class: "policy",
        condition: nil,
        rule_id: "policy.quiet"
      )

    assert {:ok, {:applied, {:fail, "policy.quiet"}, {:applied, _, _}}} =
             Relay.Delivery.fail_attempt(ctx.scope, failure)

    assert {:ok, %{"failure_kind" => "failed", "failure_rule_id" => "policy.quiet"}} =
             Relay.Delivery.delivery(ctx.scope, ctx.delivery_id)

    assert {:ok, []} = Relay.Delivery.list_dead_letters(ctx.scope)
  end
end
