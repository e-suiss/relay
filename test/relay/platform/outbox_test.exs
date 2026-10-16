defmodule Relay.Platform.OutboxTest do
  use Relay.DataCase, async: false

  alias Relay.Platform.Outbox
  alias Relay.Platform.OutboxStore
  alias Relay.Repo
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    keys = TenantFixture.keys!(tenant.live)
    recipient = TenantFixture.recipient!(tenant.live, keys)
    stream = "events:" <> TenantFixture.random()

    events =
      for n <- 1..3 do
        %{
          id: Relay.Id.generate(),
          event_type: "notification.accepted",
          stream_key: stream,
          payload: %{"n" => n}
        }
      end

    {:ok, _} =
      Relay.Ingest.accept(
        tenant.live,
        TenantFixture.accept_request([TenantFixture.notification(recipient)],
          outbox: events,
          data_key: keys.data
        )
      )

    %{scope: tenant.live, stream: stream, events: events}
  end

  defp states(scope, ids) do
    {:ok, rows} =
      OutboxStore.in_scope(scope, fn _ ->
        Repo.scoped_query!("SELECT id, state FROM relay.outbox_events WHERE id = ANY($1)", [ids]).rows
      end)

    Map.new(rows, fn [id, state] -> {id, state} end)
  end

  describe "INV-2 INV-53 OP-5 outbox dispatch" do
    test "INV-53: the batch is marked dispatched and its signal is published only after commit",
         ctx do
      parent = self()

      publish = fn topic, seq ->
        send(parent, {:published, topic, seq, Repo.in_transaction?()})
        :ok
      end

      assert {:ok, 3} = Outbox.dispatch(ctx.scope, publish: publish)

      assert_received {:published, topic, 3, false}
      assert {:ok, ^topic} = Outbox.stream_topic(ctx.scope, ctx.stream)

      assert ctx.events |> Enum.map(& &1.id) |> then(&states(ctx.scope, &1)) |> Map.values() ==
               ~w(dispatched dispatched dispatched)
    end

    test "OP-7: jobs derived from an event are written in the dispatch transaction", ctx do
      handler = fn event ->
        [
          RelayTest.TenantFixture.SendWorker.new(%{
            "outbox_event_id" => Ecto.UUID.load!(event.id)
          })
        ]
      end

      assert {:ok, 3} = Outbox.dispatch(ctx.scope, handler: handler, publish: fn _, _ -> :ok end)

      %{rows: [[count]]} =
        Repo.query!(
          "SELECT count(*) FROM relay_queue.oban_jobs WHERE args->>'outbox_event_id' = ANY($1)",
          [Enum.map(ctx.events, &Ecto.UUID.load!(&1.id))]
        )

      assert count == 3
    end

    test "OP-5: claiming reads by state in creation order; a dispatched row is not claimed again",
         ctx do
      assert {:ok, 2} = Outbox.dispatch(ctx.scope, batch: 2, publish: fn _, _ -> :ok end)
      assert {:ok, 1} = Outbox.dispatch(ctx.scope, batch: 2, publish: fn _, _ -> :ok end)
      assert {:ok, 0} = Outbox.dispatch(ctx.scope, batch: 2, publish: fn _, _ -> :ok end)

      {:ok, claimed} = OutboxStore.in_scope(ctx.scope, fn _ -> OutboxStore.claim(10) end)
      assert claimed == []
    end

    test "INV-53: a lost signal does not lose the dispatch", ctx do
      assert {:ok, 3} = Outbox.dispatch(ctx.scope, publish: fn _, _ -> {:error, :valkey_down} end)
    end

    test "TN-13: scope discovery returns scopes, never content", ctx do
      scopes = OutboxStore.pending_scopes(1_000)

      assert Enum.any?(scopes, fn {tenant_id, env, _} ->
               tenant_id == ctx.scope.tenant_id and env == "live"
             end)

      assert Enum.all?(scopes, fn entry -> tuple_size(entry) == 3 end)
    end
  end

  describe "TN-17 stream topics" do
    test "TN-17: a stream topic carries the tenant and environment", ctx do
      assert {:ok, topic} = Outbox.stream_topic(ctx.scope, "inbox:abc.def")

      assert topic ==
               "relay:t:#{Relay.Scope.tenant_text(ctx.scope)}:live:signal:stream:inbox:abc.def"

      assert Outbox.wake_topic() == "relay:s:signal:outbox"
    end
  end
end
