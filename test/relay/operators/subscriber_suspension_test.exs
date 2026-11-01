defmodule Relay.Operators.SubscriberSuspensionTest do
  use Relay.DataCase, async: false

  alias Relay.Operators.AccessSubscriberHandler
  alias Relay.Operators.SubscriberSuspension
  alias Relay.Operators.Suspension
  alias Relay.Policy.Lattice.Fake
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    TenantFixture.suspension_policy!()
    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp external, do: "user-" <> TenantFixture.random()

  defp send!(token, external_id) do
    body = %{
      "workflow" => "order-shipped",
      "to" => [%{"id" => external_id, "email" => "ayse@example.com"}],
      "data" => %{"order" => "A-1"}
    }

    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [delivery] = F.body(F.request(:get, path, token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery["id"], ["dlv"])
    {delivery, delivery_id}
  end

  defp subscriber_id(scope, external_id) do
    {:ok, %{"_id" => id}} = Relay.Subscribers.fetch(scope, external_id)
    id
  end

  defp pause_state(scope, delivery_id) do
    {:ok, [[paused?, rule, kind]]} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          """
          SELECT paused_at IS NOT NULL, pause_rule_id, failure_kind
          FROM relay.deliveries WHERE id = $1
          """,
          [delivery_id]
        ).rows
      end)

    {paused?, rule, kind}
  end

  defp audit(scope, action, target) do
    now = DateTime.utc_now()
    actor = TenantFixture.actor()
    target = Relay.Id.to_string(target)

    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.call!(
          "relay_fn.audit_query",
          [DateTime.add(now, -3_600), DateTime.add(now, 3_600), action, nil, 1_000] ++
            [TenantFixture.digest() | Relay.Actor.params(actor)]
        )
      end)

    for row <- rows, row["target_id"] == target, do: [row["actor_kind"], row["access_record_ref"]]
  end

  defp with_lattice(decision, fun) do
    previous = Application.get_env(:relay, Relay.Policy.Lattice)
    Application.put_env(:relay, Relay.Policy.Lattice, impl: Fake)
    Fake.decide(fn _delivery -> decision end)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:relay, Relay.Policy.Lattice, previous),
        else: Application.delete_env(:relay, Relay.Policy.Lattice)
    end
  end

  defp available_jobs(delivery_id) do
    [[count]] =
      Repo.query!(
        """
        SELECT count(*) FROM relay_queue.oban_jobs
        WHERE args->>'delivery_id' = $1 AND state = 'available'
        """,
        [Relay.Id.to_string(delivery_id)]
      ).rows

    count
  end

  defp complete_jobs!(delivery_id) do
    Repo.query!(
      """
      UPDATE relay_queue.oban_jobs SET state = 'completed', completed_at = now()
      WHERE args->>'delivery_id' = $1
      """,
      [Relay.Id.to_string(delivery_id)]
    )
  end

  defp suspend!(scope, id) do
    assert {:ok, %{suspended: true}} =
             SubscriberSuspension.suspend(scope, id, "abuse", TenantFixture.actor())
  end

  defp resume!(scope, id) do
    assert {:ok, %{suspended: false}} =
             SubscriberSuspension.resume(scope, id, "appeal", TenantFixture.actor())
  end

  describe "TN-73 MD-12 sends to a suspended subscriber" do
    test "TN-73, MD-12: a send is accepted and its delivery is a skip with rule subscriber.suspended",
         ctx do
      external_id = external()
      send!(ctx.token, external_id)
      suspend!(ctx.scope, subscriber_id(ctx.scope, external_id))

      {delivery, delivery_id} = send!(ctx.token, external_id)

      assert %{"status" => "skipped", "reason" => "subscriber_suspended"} = delivery
      assert delivery["rule_id"] == "subscriber.suspended"
      assert F.delivery_jobs(delivery["id"]) == []
      assert pause_state(ctx.scope, delivery_id) == {false, nil, "skipped"}

      {:ok, subscriber} = Relay.Subscribers.fetch(ctx.scope, external_id)
      assert %DateTime{} = subscriber["suspended_at"]
      assert subscriber["state"] == "active"

      read = F.body(F.request(:get, "/v1/subscribers/" <> external_id, ctx.token), 200)
      assert is_binary(read["suspended_at"])
    end

    test "TN-73: after the suspension is lifted a send opens a delivery to send again", ctx do
      external_id = external()
      send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      suspend!(ctx.scope, id)
      resume!(ctx.scope, id)

      {delivery, _delivery_id} = send!(ctx.token, external_id)
      refute delivery["reason"] == "subscriber_suspended"
      assert [_job] = F.delivery_jobs(delivery["id"])
    end
  end

  describe "TN-73 TN-40 pending work of a subscriber suspension" do
    test "TN-73, TN-40: suspension pauses the subscriber's pending deliveries only", ctx do
      external_id = external()
      {_delivery, delivery_id} = send!(ctx.token, external_id)
      {_other, other_id} = send!(ctx.token, external())

      suspend!(ctx.scope, subscriber_id(ctx.scope, external_id))

      assert pause_state(ctx.scope, delivery_id) == {true, "subscriber.suspended", nil}
      assert pause_state(ctx.scope, other_id) == {false, nil, nil}
    end

    test "TN-73, TN-40: lifting keeps deliveries PAUSED while the policy lattice is not ready",
         ctx do
      external_id = external()
      {_delivery, delivery_id} = send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      suspend!(ctx.scope, id)
      resume!(ctx.scope, id)

      assert pause_state(ctx.scope, delivery_id) == {true, "subscriber.suspended", nil}
    end

    test "TN-73, TN-40: lifting resumes through the lattice and queues the delivery job", ctx do
      external_id = external()
      {_delivery, delivery_id} = send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      suspend!(ctx.scope, id)
      complete_jobs!(delivery_id)

      with_lattice({:send, "lattice-test"}, fn -> resume!(ctx.scope, id) end)

      assert pause_state(ctx.scope, delivery_id) == {false, nil, nil}
      assert available_jobs(delivery_id) == 1
    end

    test "TN-73, TN-40: a delivery the lattice skips on resume is cancelled", ctx do
      external_id = external()
      {_delivery, delivery_id} = send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      suspend!(ctx.scope, id)

      with_lattice({:skip, "quiet_hours", "policy.quiet_hours"}, fn -> resume!(ctx.scope, id) end)

      assert {_paused?, _rule, "cancelled"} = pause_state(ctx.scope, delivery_id)
    end

    test "TN-73, TN-10: lifting a tenant suspension leaves a suspended subscriber's delivery PAUSED under its own rule",
         ctx do
      external_id = external()
      {_delivery, delivery_id} = send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      attrs = %{ground: "abuse", reason: "spam", subtenant_id: nil}
      {:ok, _row} = Suspension.suspend(ctx.tenant.id, attrs, TenantFixture.actor(), "stepup")
      suspend!(ctx.scope, id)

      with_lattice({:send, "lattice-test"}, fn ->
        {:ok, _row} = Suspension.resume(ctx.tenant.id, nil, "ok", TenantFixture.actor(), "s")
      end)

      assert pause_state(ctx.scope, delivery_id) == {true, "subscriber.suspended", nil}

      with_lattice({:send, "lattice-test"}, fn -> resume!(ctx.scope, id) end)
      assert pause_state(ctx.scope, delivery_id) == {false, nil, nil}
    end
  end

  describe "TN-73 TN-47 audit and signal" do
    test "TN-73, TN-47: suspension and resume are audited once each; repeating either changes nothing",
         ctx do
      external_id = external()
      send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      actor = TenantFixture.actor()

      assert {:ok, %{changed: true}} = SubscriberSuspension.suspend(ctx.scope, id, "a", actor)
      assert {:ok, %{changed: false}} = SubscriberSuspension.suspend(ctx.scope, id, "a", actor)
      assert {:ok, %{changed: true}} = SubscriberSuspension.resume(ctx.scope, id, "b", actor)
      assert {:ok, %{changed: false}} = SubscriberSuspension.resume(ctx.scope, id, "b", actor)

      assert [_] = audit(ctx.scope, "subscriber.suspended", id)
      assert [_] = audit(ctx.scope, "subscriber.resumed", id)
    end

    test "TN-73: an unknown subscriber is subscriber_not_found", ctx do
      assert {:error, %Relay.Error{code: :subscriber_not_found}} =
               SubscriberSuspension.suspend(
                 ctx.scope,
                 Relay.Id.generate(),
                 "x",
                 TenantFixture.actor()
               )
    end

    test "API-45, TN-73: a suspension signals the realtime layer of the tenant environment",
         ctx do
      external_id = external()
      send!(ctx.token, external_id)
      id = subscriber_id(ctx.scope, external_id)
      {:ok, topic} = SubscriberSuspension.topic(ctx.scope)
      :ok = Relay.Platform.subscribe_signal(topic)
      assert_receive {:relay_signal, ^topic, :poll}, 5_000

      suspend!(ctx.scope, id)

      assert_receive {:relay_signal, ^topic, {:seq, version}}, 5_000
      assert is_integer(version) and version > 1
      Relay.Platform.unsubscribe_signal(topic)
    end
  end

  describe "TN-73 TN-20 Access user events" do
    test "TN-73: user.suspended suspends the subscriber whose external_id is the pairwise sub and user.reactivated lifts it",
         ctx do
      sub = "pairwise-" <> TenantFixture.random()
      {_delivery, delivery_id} = send!(ctx.token, sub)
      id = subscriber_id(ctx.scope, sub)

      assert :ok = AccessSubscriberHandler.handle_user_event(:suspended, sub, "evt-s")
      assert {:ok, %{"suspended_at" => %DateTime{}}} = Relay.Subscribers.fetch(ctx.scope, sub)
      assert pause_state(ctx.scope, delivery_id) == {true, "subscriber.suspended", nil}
      assert [["access", "evt-s"]] = audit(ctx.scope, "subscriber.suspended", id)

      assert :ok = AccessSubscriberHandler.handle_user_event(:suspended, sub, "evt-s")
      assert [_] = audit(ctx.scope, "subscriber.suspended", id)

      assert :ok = AccessSubscriberHandler.handle_user_event(:reactivated, sub, "evt-r")
      assert {:ok, %{"suspended_at" => nil}} = Relay.Subscribers.fetch(ctx.scope, sub)
      assert [["access", "evt-r"]] = audit(ctx.scope, "subscriber.resumed", id)
    end

    test "TN-73: an unknown sub and user.deleted change no subscriber", ctx do
      sub = "pairwise-" <> TenantFixture.random()
      send!(ctx.token, sub)

      assert :ok = AccessSubscriberHandler.handle_user_event(:suspended, "nobody", "evt-1")
      assert :ok = AccessSubscriberHandler.handle_user_event(:deleted, sub, "evt-2")
      assert {:ok, %{"suspended_at" => nil}} = Relay.Subscribers.fetch(ctx.scope, sub)
    end

    test "TN-73, TN-20: the subscriber handler is registered next to the operator handler" do
      handlers = Keyword.fetch!(Relay.Access.config(), :user_handlers)
      assert Relay.Operators.AccessUserHandler in handlers
      assert AccessSubscriberHandler in handlers
    end
  end
end
