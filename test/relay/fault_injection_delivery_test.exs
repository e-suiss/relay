defmodule Relay.FaultInjectionDeliveryTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Live
  alias Relay.Channels.Live.ReceiptWorker
  alias Relay.Datasets
  alias Relay.FaultInjection.Cache
  alias Relay.FaultInjection.Record
  alias Relay.Iys.SyncWorker
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "channel_parameters"]
  @attempts "SELECT attempt_no, state, failure_class, raw_code FROM relay.delivery_attempts
    WHERE delivery_id = $1 ORDER BY attempt_no"
  @retry "SELECT args FROM relay_queue.oban_jobs WHERE worker = 'Relay.Delivery.Send'
    AND args->>'delivery_id' = $1 ORDER BY id DESC LIMIT 1"

  defp forget do
    for name <- @datasets,
        do: :ok = Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())

    on_exit(fn ->
      forget()
      Cache.forget()
    end)

    tenant = TenantFixture.tenant!()
    %{scope: tenant.test, token: F.token(tenant.test)}
  end

  defp record(scope, kind, fields \\ []) do
    struct!(
      Record,
      Map.merge(
        %{
          id: Relay.Id.generate(),
          scope_kind: :tenant,
          scope_tenant_id: scope.tenant_id,
          target_environment: scope.environment,
          channel: nil,
          provider: nil,
          kind: kind,
          rate_percent: 100,
          delay_ms: nil,
          status: :active,
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        },
        Map.new(fields)
      )
    )
  end

  defp sms_delivery!(ctx) do
    F.workflow!(ctx.scope, ctx.token, "order-shipped", channels: ["sms"])
    to = %{"id" => "user-" <> TenantFixture.random(), "phone" => "+905551112233"}
    event = %{"workflow" => "order-shipped", "to" => [to], "data" => %{"order" => "A-1"}}
    accepted = F.body(F.request(:post, "/v1/events", ctx.token, event), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, ctx.token), 200)["data"]
    {:ok, id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    id
  end

  defp attempts(scope, id) do
    {:ok, rows} = Repo.in_scope(scope, fn _ -> Repo.scoped_query!(@attempts, [id]).rows end)
    rows
  end

  defp retry_args(id) do
    case Repo.query!(@retry, [Relay.Id.to_string(id)]).rows do
      [[args]] -> args
      [] -> %{}
    end
  end

  describe "OP-49 OP-92 provider faults on the delivery path" do
    test "OP-49: an injected provider outage fails the attempt without the provider and the retry sends once",
         ctx do
      id = sms_delivery!(ctx)
      Cache.put([record(ctx.scope, :concurrency_exhausted)])

      _ = Live.deliver(ctx.scope, id, %{})

      assert [[1, "failed", "transient", "chaos:concurrency_exhausted"]] =
               attempts(ctx.scope, id)

      Cache.put([])
      args = retry_args(id)
      _ = Live.deliver(ctx.scope, id, args)
      _ = Live.deliver(ctx.scope, id, args)

      rows = attempts(ctx.scope, id)
      succeeded = Enum.count(rows, fn [_n, state, _class, _code] -> state == "succeeded" end)
      assert succeeded <= 1
      assert Enum.count(rows, fn [_n, _state, _class, code] -> code =~ "chaos:" end) == 1
    end

    test "OP-92: a fault of another tenant, channel or environment leaves the call alone", ctx do
      id = sms_delivery!(ctx)
      other = record(ctx.scope, :provider_auth_error, scope_tenant_id: Relay.Id.generate())
      email = record(ctx.scope, :provider_auth_error, channel: "email")
      live = record(ctx.scope, :provider_auth_error, target_environment: :live)
      Cache.put([other, email, live])

      _ = Live.deliver(ctx.scope, id, %{})

      refute Enum.any?(attempts(ctx.scope, id), fn [_n, _state, _class, code] ->
               is_binary(code) and code =~ "chaos:"
             end)
    end

    test "OP-92: a delayed delivery report snoozes its receipt job until the delay passed", ctx do
      Cache.put([record(ctx.scope, :delayed_delivery_report, delay_ms: 60_000)])

      args =
        ctx.scope
        |> Relay.Scope.to_job_args()
        |> Map.put("receipt_ids", [Relay.Id.to_string(Relay.Id.generate())])

      job = %Oban.Job{id: 7, args: args, inserted_at: DateTime.utc_now()}
      assert {:snooze, seconds} = ReceiptWorker.perform(job)
      assert seconds in 59..60

      old = %{job | inserted_at: DateTime.add(DateTime.utc_now(), -61, :second)}
      refute match?({:snooze, _}, ReceiptWorker.perform(old))
    end

    test "OP-92: a stalled İYS pull ends its job without pulling", ctx do
      Cache.put([record(ctx.scope, :iys_pull_stalled)])
      job = %Oban.Job{args: Relay.Scope.to_job_args(ctx.scope)}
      assert SyncWorker.perform(job) == :ok
    end
  end
end
