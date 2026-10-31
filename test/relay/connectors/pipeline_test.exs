defmodule Relay.Connectors.PipelineTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Clients
  alias Relay.Connectors.Connector
  alias Relay.Repo
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @set_status "SELECT * FROM relay_fn.api_client_set_status($1, $2, $3, $4, $5, $6, $7, $8)"

  setup do
    :ok = Clients.reset()
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")

    mapping = %{
      "type" => "com.shop.order.shipped",
      "workflow" => "order-shipped",
      "to_pointer" => "/customer",
      "data_fields" => ["/order"]
    }

    assert F.request(:post, "/v1/event_type_mappings", token, mapping).status == 201
    client = FakeAccess.client!(tenant.live, ["publish"])

    connector = %Connector{
      name: :pipeline_test,
      source: :test,
      producer: {Broadway.DummyProducer, []},
      access_tenant_id: tenant.attrs.access_tenant_id,
      access_client_id: client,
      concurrency: 2,
      hold_ms: 50,
      max_wait_ms: 50
    }

    %{scope: tenant.live, client: client, connector: connector}
  end

  defp start!(connector), do: start_supervised!(Relay.Connectors.child_spec(connector))

  defp send!(connector, data), do: Broadway.test_message(Connector.process_name(connector), data)

  defp cloudevent(id, overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => id,
        "source" => "https://shop.example.com/orders",
        "type" => "com.shop.order.shipped",
        "data" => %{
          "order" => "A-9",
          "customer" => %{"id" => "ce-" <> TenantFixture.random(), "email" => "c@example.com"}
        }
      },
      overrides
    )
  end

  defp events(scope) do
    {:ok, [[n]]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!("SELECT count(*) FROM relay.events", []).rows
      end)

    n
  end

  defp set_status(scope, client, status) do
    {:ok, actor} = Relay.Actor.new(:access, "access", "access")
    params = [client, status, "evt_status", TenantFixture.digest()] ++ Relay.Actor.params(actor)

    {:ok, [[_result, generation]]} =
      Repo.in_scope(scope, fn _status -> Repo.query!(@set_status, params).rows end)

    :ok = Clients.advance(generation)
  end

  describe "T-41 INV-2 API-16 API-31 ingest connectors" do
    test "T-41: a source message is accepted through the event acceptance path, then acked",
         ctx do
      start!(ctx.connector)
      ref = send!(ctx.connector, Jason.encode!(cloudevent("order-1")))

      assert_receive {:ack, ^ref, [%{status: :ok}], []}, 5_000
      assert events(ctx.scope) == 1
    end

    test "API-31: a message the source delivers again is acked and opens no second event",
         ctx do
      start!(ctx.connector)
      data = Jason.encode!(cloudevent("order-2"))

      for _ <- 1..2 do
        ref = send!(ctx.connector, data)
        assert_receive {:ack, ^ref, [_accepted], []}, 5_000
      end

      assert events(ctx.scope) == 1
    end

    test "T-41: a message that can never be accepted is failed with its error code", ctx do
      start!(ctx.connector)
      unmapped = cloudevent("order-3", %{"type" => "com.shop.unknown"})

      for {data, code} <- [
            {"not json", "malformed_request"},
            {Jason.encode!([cloudevent("order-4")]), "malformed_request"},
            {Jason.encode!(unmapped), "event_type_not_mapped"},
            {Jason.encode!(Map.delete(cloudevent("order-5"), "source")), "validation_failed"}
          ] do
        ref = send!(ctx.connector, data)
        assert_receive {:ack, ^ref, [], [%{status: {:failed, ^code}}]}, 5_000
      end

      assert events(ctx.scope) == 0
    end

    test "INV-2: a message of a suspended client waits unacknowledged until it can be accepted",
         ctx do
      set_status(ctx.scope, ctx.client, "suspended")
      start!(ctx.connector)
      ref = send!(ctx.connector, Jason.encode!(cloudevent("order-6")))

      refute_receive {:ack, ^ref, _successful, _failed}, 500
      assert events(ctx.scope) == 0

      set_status(ctx.scope, ctx.client, "active")
      assert_receive {:ack, ^ref, [_accepted], []}, 5_000
      assert events(ctx.scope) == 1
    end

    test "T-41: every attempt is reported without the message contents", ctx do
      handler = "connector-test-" <> TenantFixture.random()
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler,
          [:relay, :connector, :message],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:connector, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      start!(ctx.connector)
      send!(ctx.connector, Jason.encode!(cloudevent("order-7")))

      assert_receive {:connector, %{count: 1}, metadata}, 5_000
      assert metadata == %{connector: :pipeline_test, result: :accepted, code: nil}
    end
  end
end
