defmodule Relay.Agents.CorrelationDigestTest do
  use Relay.SqlCase, async: true

  import RelayTest.WaitpointFixture

  alias Relay.Agents.Correlation
  alias Relay.Agents.CorrelationDigestBackfill
  alias Relay.Agents.Waitpoint
  alias RelayTest.TenantFixture

  @fill "SELECT relay_fn.correlation_digest_fill($1, $2, $3, $4)"
  @plain "SELECT source, id FROM relay_fn.correlation_plain_batch(10) ORDER BY source"
  @legacy "SELECT id FROM relay.waitpoints WHERE correlation_key IS NOT NULL"
  @waitpoint "SELECT correlation_key, correlation_digest FROM relay.waitpoints WHERE id = $1"
  @record "SELECT correlation_key, correlation_digest FROM relay.mailbox_records WHERE id = $1"
  @unmatched "SELECT count(*) FROM relay.waitpoint_unmatched_events WHERE correlation_key IS NOT NULL"
  @change "UPDATE relay.waitpoints SET correlation_digest = $2 WHERE id = $1"

  setup do
    scenario()
  end

  defp scenario do
    s = setup!()
    %{s: s, agent: member!(s, "agent")}
  end

  defp as_owner(fun) do
    admin = connect(:admin)

    try do
      rolled_back(admin, fn ->
        ctx = scenario()
        rows("SET LOCAL ROLE relay_owner")
        fun.(ctx)
      end)
    after
      GenServer.stop(admin)
    end
  end

  defp legacy_waitpoint(id) do
    one(
      """
      INSERT INTO relay.waitpoints (tenant_id, environment, id, kind, waiter_kind, waiter_ref,
        waiter_mailbox_id, match_event_type, correlation_key, opened_at, expires_at, state,
        state_changed_at, created_at, updated_at)
      SELECT tenant_id, environment, $2, 'event', waiter_kind, waiter_ref, waiter_mailbox_id,
        match_event_type, 'legacy-key', now(), now() + interval '1 hour', 'open', now(), now(),
        now()
      FROM relay.waitpoints WHERE id = $1
      RETURNING created_at
      """,
      [id, id()]
    )
  end

  defp legacy_record(record_id) do
    row(
      """
      INSERT INTO relay.mailbox_records (tenant_id, environment, id, created_at, mailbox_id, epoch,
        seq, kind, event_type, correlation_key, payload_digest, delivery_state, updated_at)
      SELECT tenant_id, environment, $2, created_at, mailbox_id, epoch, seq + 1000, kind,
        event_type, 'legacy-key', payload_digest, delivery_state, now()
      FROM relay.mailbox_records WHERE id = $1
      RETURNING id, created_at
      """,
      [record_id, id()]
    )
  end

  defp real_scope do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()
    {tenant.test, TenantFixture.recipient!(tenant.test, %{}, kind: :agent)}
  end

  defp stored(scope, sql, id) do
    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status -> Relay.Repo.scoped_query!(sql, [id]).rows end)

    rows
  end

  defp open_event(scope, agent, key) do
    Waitpoint.open(scope, %{
      id: Relay.Id.generate(),
      kind: :event,
      waiter_kind: :agent,
      waiter_ref: agent,
      match_event_type: "order.paid",
      correlation_key: key,
      expires_at: DateTime.add(Relay.Clock.business_now(scope), 1, :hour)
    })
  end

  defp offer_event(scope, agent, key) do
    Waitpoint.offer_event(scope, %{
      event_type: "order.paid",
      correlation_key: key,
      waiter_kind: :agent,
      waiter_ref: agent,
      payload_digest: TenantFixture.digest()
    })
  end

  describe "AG-65 the correlation key is stored only as a keyed digest" do
    test "AG-65: the digest is keyed per scope and bound to the event type" do
      {scope, _agent} = real_scope()
      {other_scope, _agent} = real_scope()

      assert {:ok, [<<_::256>> = digest | _]} = Correlation.digests(scope, "order.paid", "o-1")
      assert {:ok, [^digest | _]} = Correlation.digests(scope, "order.paid", "o-1")
      assert {:ok, [other | _]} = Correlation.digests(scope, "order.shipped", "o-1")
      assert {:ok, [foreign | _]} = Correlation.digests(other_scope, "order.paid", "o-1")
      refute other == digest
      refute foreign == digest
      refute digest == :crypto.hash(:sha256, "o-1")
    end

    test "AG-65: a buffered event and the waitpoint it resolves hold the digest, never the key" do
      {scope, agent} = real_scope()
      key = "person@example.com-" <> TenantFixture.random()
      {:ok, [digest | _]} = Correlation.digests(scope, "order.paid", key)

      assert {:ok, %{result: :buffered, record_id: record_id}} = offer_event(scope, agent, key)

      assert {:ok, %{result: :opened, waitpoint_id: id, early: {:resolved_by_event, :resolved}}} =
               open_event(scope, agent, key)

      assert [[nil, ^digest]] = stored(scope, @waitpoint, id)
      assert [[nil, ^digest]] = stored(scope, @record, record_id)

      assert {:ok, waitpoint} = Waitpoint.get(scope, id)
      refute Map.has_key?(waitpoint, :correlation_key)
      refute inspect(waitpoint) =~ key
    end

    test "AG-65: an unmatched event is recorded with the digest" do
      assert [["unmatched", nil, nil]] = offer("order.paid", "nobody-" <> Base.encode16(digest()))
      assert one(@unmatched) == 0
    end

    test "AG-65: the digest of a waitpoint does not change" do
      as_owner(fn ctx ->
        ["opened", id, _, nil] = open(ctx.s, kind: "event", waiter_ref: ctx.agent)
        error = sql_error(@change, [id, digest()])
        assert error.postgres.message == "invariant_violation"
        assert error.postgres.hint == "AG-11"
      end)
    end

    test "AG-65: keys stored in clear before AG-65 are replaced by their digests once" do
      as_owner(fn ctx ->
        ["opened", id, _, nil] = open(ctx.s, kind: "event", waiter_ref: ctx.agent)

        [["buffered", nil, record_id]] =
          offer("agent.answer", "early", waiter_kind: "agent", waiter_ref: ctx.agent)

        legacy_created = legacy_waitpoint(id)
        [[legacy_id]] = rows(@legacy)
        [legacy_record, record_created] = legacy_record(record_id)

        assert rows(@plain) == [["mailbox_record", legacy_record], ["waitpoint", legacy_id]]

        sources = ["waitpoint", "mailbox_record"]
        ids = [legacy_id, legacy_record]
        created = [legacy_created, record_created]
        digests = [ck("legacy-key"), ck("legacy-key")]

        assert one(@fill, [sources, ids, created, digests]) == 2
        assert one(@fill, [sources, ids, created, digests]) == 0
        assert rows(@plain) == []
        assert row(@waitpoint, [legacy_id]) == [nil, ck("legacy-key")]
        assert row(@record, [legacy_record]) == [nil, ck("legacy-key")]
      end)
    end

    test "AG-65: a new scope has nothing to backfill and a finished pass stays idle" do
      {scope, _agent} = real_scope()
      assert {:ok, %{scanned: 0, updated: 0}} = Correlation.backfill(scope, 10)

      state = %{"finished_at" => "2026-12-16T00:00:00Z", "scanned" => 2, "updated" => 2}

      assert {:ok, ^state, delay} =
               CorrelationDigestBackfill.run(%{
                 name: "correlation_digest_backfill",
                 node: "n",
                 fencing_token: 1,
                 state: state
               })

      assert delay >= 3_600_000
    end
  end
end
