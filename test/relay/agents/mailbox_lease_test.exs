defmodule Relay.Agents.MailboxLeaseTest do
  use Relay.DataCase, async: false

  alias Relay.Agents
  alias Relay.Agents.Mailbox
  alias Relay.Inbox.Mailbox, as: Core
  alias Relay.Platform.VirtualClock
  alias Relay.Repo
  alias RelayTest.OutboxEvents
  alias RelayTest.TenantFixture

  defmodule Transport do
    @moduledoc false
    @behaviour Relay.Agents.WakeHint

    @impl Relay.Agents.WakeHint
    def jobs(hint) do
      send(self(), {:wake, hint})
      []
    end
  end

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    agent = TenantFixture.recipient!(scope, %{}, kind: :agent)
    owner = {:agent, agent}
    {:ok, mailbox} = Agents.mailbox(scope, owner)
    %{scope: scope, agent: agent, owner: owner, mailbox: mailbox.id}
  end

  defp append!(ctx, opts \\ []) do
    id = Relay.Id.generate()
    kind = Keyword.get(opts, :kind, :message)

    record = %{
      id: id,
      mailbox_id: Keyword.get(opts, :mailbox, ctx.mailbox),
      kind: kind,
      event_type: "agent.note",
      correlation_digest: if(kind == :early_event, do: :crypto.strong_rand_bytes(32)),
      payload_digest: :crypto.strong_rand_bytes(32)
    }

    {:ok, {:appended, _epoch, seq}} = Core.append(ctx.scope, record)
    %{id: id, seq: seq}
  end

  defp lease!(ctx, max, seconds) do
    :ok = move_to!(ctx, seconds)
    {:ok, lease} = Agents.lease_mailbox(ctx.scope, ctx.owner, max)
    lease
  end

  defp move_to!(ctx, seconds) do
    passed = Process.get(:virtual_seconds, 0)

    if seconds > passed do
      step = (seconds - passed) * 1000
      actor = TenantFixture.actor()
      advanced = VirtualClock.advance(ctx.scope, step, TenantFixture.digest(), actor)
      assert {:ok, {:advanced, _offset, _now}} = advanced
      Process.put(:virtual_seconds, seconds)
    end

    :ok
  end

  defp ack!(ctx, lease, ids) do
    {:ok, acked} = Agents.ack_mailbox(ctx.scope, ctx.owner, lease.lease_id, ids)
    acked
  end

  defp setting!(scope, value) do
    change = %{
      key: "mailbox.lease",
      value: value,
      expected_version: nil,
      record_digest: TenantFixture.digest()
    }

    Relay.Tenancy.put_setting(scope, change, TenantFixture.actor())
  end

  defp count(scope, mailbox) do
    sql = "SELECT count(*) FROM relay.mailbox_records r WHERE r.mailbox_id = $1"
    {:ok, [[count]]} = Repo.in_scope(scope, fn _ -> Repo.scoped_query!(sql, [mailbox]).rows end)
    count
  end

  defp set_state!(ctx, state, reason \\ nil) do
    {:ok, [%{"mailbox_set_state" => "changed"}]} =
      Repo.in_scope(ctx.scope, fn _status ->
        Repo.call!("relay_fn.mailbox_set_state", [ctx.mailbox, state, reason])
      end)

    :ok
  end

  describe "AG-20 AG-64 the agent face of the mailbox" do
    test "AG-64: an API client has a mailbox of its own, opened lazily and once", ctx do
      client = {:api_client, Relay.Id.generate()}

      assert {:ok, %{id: id, owner: ^client, state: :active} = opened} =
               Agents.mailbox(ctx.scope, client)

      assert opened.head == %{epoch: 1, seq: 0}
      assert opened.acked == %{epoch: 1, seq: 0}
      assert id != ctx.mailbox
      assert {:ok, %{id: ^id}} = Agents.mailbox(ctx.scope, client)

      first = append!(ctx, mailbox: id)
      assert {:ok, %{records: [record]} = lease} = Agents.lease_mailbox(ctx.scope, client, 10)
      assert record["id"] == first.id
      assert {:ok, %{results: results}} =
               Agents.ack_mailbox(ctx.scope, client, lease.lease_id, [first.id])

      assert results == [{first.id, :acked}]
    end

    test "AG-64: an agent that does not exist has no mailbox", ctx do
      assert {:error, :owner_not_found} = Agents.mailbox(ctx.scope, {:agent, Relay.Id.generate()})
    end

    test "AG-20: a record goes to one lease, is acknowledged by it once and is not handed out again",
         ctx do
      [a, b, c] = for _ <- 1..3, do: append!(ctx)

      first = lease!(ctx, 2, 0)
      assert Enum.map(first.records, & &1["id"]) == [a.id, b.id]
      assert Enum.map(first.records, & &1["delivery_count"]) == [1, 1]
      assert %DateTime{} = first.lease_until
      assert Enum.all?(first.records, &(&1["lease_until"] == first.lease_until))

      second = lease!(ctx, 10, 1)
      assert Enum.map(second.records, & &1["id"]) == [c.id]
      assert %{records: [], lease_until: nil} = lease!(ctx, 10, 2)
      refute first.lease_id == second.lease_id

      assert ack!(ctx, second, [a.id]).results == [{a.id, :lease_lost}]

      assert %{results: [{id, :acked}], acked: %{epoch: 1, seq: seq}} = ack!(ctx, first, [a.id])
      assert {id, seq} == {a.id, a.seq}
      assert ack!(ctx, first, [a.id]).results == [{a.id, :already_acked}]

      unknown = Relay.Id.generate()
      assert ack!(ctx, first, [unknown]).results == [{unknown, :not_found}]

      assert ack!(ctx, first, [b.id]).acked.seq == b.seq
      assert ack!(ctx, second, [c.id]).acked.seq == c.seq
      assert lease!(ctx, 10, 3_600).records == []
    end

    test "AG-20: a record that is not acknowledged within the lease is delivered again", ctx do
      record = append!(ctx)

      first = lease!(ctx, 1, 0)
      assert [%{"delivery_count" => 1}] = first.records
      assert lease!(ctx, 1, 59).records == []

      second = lease!(ctx, 1, 61)
      assert [%{"id" => id, "delivery_count" => 2}] = second.records
      assert id == record.id
      assert DateTime.diff(second.lease_until, first.lease_until, :second) == 61

      assert ack!(ctx, first, [record.id]).results == [{record.id, :lease_lost}]
      assert ack!(ctx, second, [record.id]).results == [{record.id, :acked}]
      assert lease!(ctx, 1, 3_600).records == []
    end
  end

  describe "AG-22 AG-53 lease settings and dead letters" do
    test "AG-22: the lease duration and the redelivery count are tenant settings within the published limits",
         ctx do
      assert Agents.mailbox_limits() == %{
               lease_ms: %{default: 60_000, min: 10_000, max: 900_000},
               redeliveries: %{default: 5, min: 1, max: 20},
               lease_max_records: 100
             }

      assert {:ok, %{settings: %{lease_ms: 60_000, max_redeliveries: 5}}} =
               Agents.mailbox(ctx.scope, ctx.owner)

      assert {:ok, _} = setting!(ctx.scope, %{"lease_seconds" => 900, "max_redeliveries" => 20})

      assert {:ok, %{settings: %{lease_ms: 900_000, max_redeliveries: 20}}} =
               Agents.mailbox(ctx.scope, ctx.owner)

      assert {:ok, _} = setting!(ctx.scope, %{"lease_seconds" => 10})

      assert {:ok, %{settings: %{lease_ms: 10_000, max_redeliveries: 5}}} =
               Agents.mailbox(ctx.scope, ctx.owner)

      for value <- [
            %{"lease_seconds" => 9},
            %{"lease_seconds" => 901},
            %{"max_redeliveries" => 0},
            %{"max_redeliveries" => 21},
            %{"lease_ms" => 1_000},
            %{}
          ] do
        assert {:error, %Relay.Error{code: :invalid_setting}} = setting!(ctx.scope, value)
      end

      assert Mailbox.settings(%{"lease_seconds" => 5, "max_redeliveries" => 99}) ==
               %{lease_ms: 60_000, max_redeliveries: 5}
    end

    test "AG-53: one lease request takes at most the published number of records", ctx do
      limit = Agents.mailbox_limits().lease_max_records
      assert_raise FunctionClauseError, fn -> Mailbox.lease_in(ctx.owner, limit + 1) end
      assert {:ok, %{records: []}} = Agents.lease_mailbox(ctx.scope, ctx.owner, limit)
    end

    test "AG-22: a record past the redelivery count moves to the dead letters, is kept and its event is written",
         ctx do
      assert {:ok, _} = setting!(ctx.scope, %{"lease_seconds" => 10, "max_redeliveries" => 1})
      record = append!(ctx)
      kept = append!(ctx)

      first = lease!(ctx, 1, 0)
      assert [%{"delivery_count" => 1}] = first.records
      second = lease!(ctx, 1, 11)
      assert [%{"id" => id, "delivery_count" => 2}] = second.records
      assert id == record.id

      third = lease!(ctx, 2, 22)
      assert Enum.map(third.records, & &1["id"]) == [kept.id]

      assert {:ok, [dead]} = Agents.mailbox_dead_letters(ctx.scope, ctx.owner, nil, 10)
      assert dead["id"] == record.id
      assert dead["delivery_state"] == "dead_lettered"
      assert dead["delivery_count"] == 2
      assert DateTime.diff(dead["dead_lettered_at"], second.lease_until, :second) == 1

      assert {:ok, %{"delivery_state" => "dead_lettered"}} =
               Agents.mailbox_record(ctx.scope, record.id, ctx.owner)

      assert count(ctx.scope, ctx.mailbox) == 2
      assert ack!(ctx, second, [record.id]).results == [{record.id, :lease_lost}]
      assert Enum.map(lease!(ctx, 10, 3_600).records, & &1["id"]) == [kept.id]

      assert OutboxEvents.data(ctx.scope, "mailbox.record_dead_lettered") == [
               %{
                 "mailbox_id" => Relay.ExternalId.encode("mbx", ctx.mailbox),
                 "record_id" => Relay.ExternalId.encode("mbr", record.id)
               }
             ]

      assert {:ok, %{acked: %{seq: seq}}} = Agents.mailbox(ctx.scope, ctx.owner)
      assert seq == kept.seq - 1
    end

    test "AG-22: the dead letter view of another mailbox is read by its identifier", ctx do
      assert {:ok, []} = Agents.mailbox_dead_letters(ctx.scope, {:id, ctx.mailbox}, nil, 10)

      assert {:ok, []} =
               Agents.mailbox_dead_letters(ctx.scope, {:api_client, Relay.Id.generate()}, nil, 10)

      assert {:error, :not_found} =
               Agents.mailbox_dead_letters(ctx.scope, {:id, Relay.Id.generate()}, nil, 10)
    end
  end

  describe "AG-24 reading order" do
    test "AG-24: records are read in sequence order after a position and a gap is filled with since",
         ctx do
      [a, b] = for _ <- 1..2, do: append!(ctx)
      held = append!(ctx, kind: :early_event)
      [c, d] = for _ <- 1..2, do: append!(ctx)
      seqs = Enum.map([a, b, held, c, d], & &1.seq)
      assert seqs == Enum.sort(seqs)

      assert {:ok, %{records: page, has_more: true, position: position}} =
               Agents.read_mailbox(ctx.scope, ctx.owner, nil, 2)

      assert Enum.map(page, & &1["seq"]) == [a.seq, b.seq]
      assert position == %{epoch: 1, seq: b.seq}

      assert {:ok, %{records: rest, has_more: false, position: head}} =
               Agents.read_mailbox(ctx.scope, ctx.owner, position, 100)

      assert Enum.map(rest, & &1["id"]) == [c.id, d.id]
      assert head == %{epoch: 1, seq: d.seq}

      assert {:ok, %{records: [], has_more: false}} =
               Agents.read_mailbox(ctx.scope, ctx.owner, head, 100)

      assert {:ok, %{records: gap}} =
               Agents.read_mailbox(ctx.scope, ctx.owner, %{epoch: 1, seq: a.seq}, 100)

      assert Enum.map(gap, & &1["id"]) == [b.id, c.id, d.id]

      lease = lease!(ctx, 100, 0)
      assert Enum.map(lease.records, & &1["id"]) == [a.id, b.id, c.id, d.id]
      assert {:ok, nil} = Agents.mailbox_record(ctx.scope, held.id, ctx.owner)
    end

    test "AG-20: a reader that wakes up continues after the acknowledged position", ctx do
      [a, b, c] = for _ <- 1..3, do: append!(ctx)
      lease = lease!(ctx, 3, 0)
      assert ack!(ctx, lease, [a.id, c.id]).acked == %{epoch: 1, seq: a.seq}

      assert {:ok, %{records: missed}} = Agents.read_mailbox(ctx.scope, ctx.owner, nil, 100)
      assert Enum.map(missed, & &1["id"]) == [b.id, c.id]
      assert Enum.map(missed, & &1["delivery_state"]) == ["leased", "acked"]

      assert {:resync_required, %{epoch: 1, seq: seq}} =
               Agents.read_mailbox(ctx.scope, ctx.owner, %{epoch: 2, seq: 0}, 100)

      assert seq == a.seq

      assert {:resync_required, _acked} =
               Agents.read_mailbox(ctx.scope, ctx.owner, %{epoch: 1, seq: c.seq + 1}, 100)
    end
  end

  describe "AG-21 wake hint and durable handle" do
    setup do
      previous = Application.get_env(:relay, Agents, [])
      configured = Keyword.put(previous, :wake_transports, [Transport])
      Application.put_env(:relay, Agents, configured)
      on_exit(fn -> Application.put_env(:relay, Agents, previous) end)
    end

    test "AG-21: the hint names the record and its position and nothing else", ctx do
      record = append!(ctx)
      test = self()

      handler = fn event ->
        send(test, {:event, event})
        Relay.Webhooks.Live.outbox_jobs(event)
      end

      assert {:ok, dispatched} =
               Relay.Platform.dispatch_outbox(ctx.scope,
                 handler: handler,
                 publish: fn _topic, _seq -> :ok end
               )

      assert dispatched >= 1
      assert_received {:wake, hint}

      assert hint == %{
               mailbox_id: Relay.Id.to_string(ctx.mailbox),
               record_id: Relay.Id.to_string(record.id),
               epoch: 1,
               seq: record.seq,
               kind: "message",
               traceparent: nil
             }

      assert_received {:event, %{event_type: "mailbox.record_appended"} = event}
      data = Relay.Platform.outbox_thin_data(event)

      assert data == %{
               "mailbox_id" => Relay.ExternalId.encode("mbx", ctx.mailbox),
               "record_id" => Relay.ExternalId.encode("mbr", record.id),
               "kind" => "message",
               "epoch" => 1,
               "seq" => record.seq
             }

      assert {:ok, %{data: schema}} = Relay.EventCatalog.fetch("mailbox.record_appended")
      assert schema["required"] -- Map.keys(data) == []
      assert Map.keys(data) -- Map.keys(schema["properties"]) == []

      assert {:ok, %{"id" => id, "seq" => seq}} =
               Agents.mailbox_record(ctx.scope, record.id, :any)

      assert {id, seq} == {record.id, record.seq}
    end

    test "AG-21: a hint that is never sent or is lost loses no record", ctx do
      records = for _ <- 1..3, do: append!(ctx)

      assert {:ok, [["pending"]]} =
               Repo.in_scope(ctx.scope, fn _status ->
                 Repo.scoped_query!(
                   "SELECT DISTINCT o.state FROM relay.outbox_events o WHERE o.event_type = $1",
                   ["mailbox.record_appended"]
                 ).rows
               end)

      refute_received {:wake, _hint}

      assert {:ok, _count} =
               Relay.Platform.dispatch_outbox(ctx.scope,
                 handler: fn _event -> [] end,
                 publish: fn _topic, _seq -> {:error, :lost} end
               )

      lease = lease!(ctx, 10, 0)
      assert Enum.map(lease.records, & &1["id"]) == Enum.map(records, & &1.id)
    end

    test "AG-21: an event that is not a mailbox record gives no hint" do
      event = %{event_type: "waitpoint.resolved", payload: %{}, epoch: 1, seq: 1}
      assert Agents.wake_jobs(event) == []
      refute_received {:wake, _hint}
    end
  end

  describe "AG-23 INV-47 retention and ownership" do
    test "AG-23: a suspended mailbox hands out no lease and keeps its records", ctx do
      record = append!(ctx)
      :ok = set_state!(ctx, "suspended")

      assert {:error, :inactive} = Agents.lease_mailbox(ctx.scope, ctx.owner, 1)
      assert {:ok, %{state: :suspended}} = Agents.mailbox(ctx.scope, ctx.owner)
      assert {:ok, %{records: [read]}} = Agents.read_mailbox(ctx.scope, ctx.owner, nil, 10)
      assert read["id"] == record.id
      assert count(ctx.scope, ctx.mailbox) == 1

      :ok = set_state!(ctx, "active")
      assert [%{"id" => id}] = lease!(ctx, 1, 0).records
      assert id == record.id
    end

    test "AG-23, INV-47: erasing the agent closes its mailbox and removes no leased or dead-lettered record",
         ctx do
      assert {:ok, _} = setting!(ctx.scope, %{"lease_seconds" => 10, "max_redeliveries" => 1})
      dead = append!(ctx)
      _first = lease!(ctx, 1, 0)
      _second = lease!(ctx, 1, 11)
      leased = append!(ctx)
      third = lease!(ctx, 2, 22)
      assert Enum.map(third.records, & &1["id"]) == [leased.id]

      params =
        [ctx.agent, "dsr_1", ["recipient_profile"], [], TenantFixture.digest()] ++
          Relay.Actor.params(TenantFixture.actor())

      assert {:ok, [%{"result" => "erased"}]} =
               Repo.in_scope(ctx.scope, fn _status ->
                 Repo.call!("relay_fn.subject_erase", params)
               end)

      assert {:error, :not_found} = Agents.mailbox(ctx.scope, ctx.owner)
      assert {:error, :not_found} = Agents.lease_mailbox(ctx.scope, ctx.owner, 1)
      assert count(ctx.scope, ctx.mailbox) == 2

      assert {:ok, [%{"id" => id}]} =
               Agents.mailbox_dead_letters(ctx.scope, {:id, ctx.mailbox}, nil, 10)

      assert id == dead.id

      assert {:ok, %{"delivery_state" => "leased"}} =
               Agents.mailbox_record(ctx.scope, leased.id, :any)
    end
  end
end
