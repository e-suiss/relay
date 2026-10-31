defmodule Relay.Operators.SuspensionWorkTest do
  use Relay.DataCase, async: false

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
    %{tenant: tenant, token: token}
  end

  defp accept!(token, overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "workflow" => "order-shipped",
          "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
          "data" => %{"order" => "A-1"}
        },
        overrides
      )

    accepted = F.body(F.request(:post, "/v1/events", token, body), 202)
    [%{"notification_id" => notification}] = accepted["notifications"]
    path = "/v1/notifications/#{notification}/deliveries"
    [%{"id" => delivery}] = F.body(F.request(:get, path, token), 200)["data"]
    {:ok, delivery_id} = Relay.ExternalId.decode(delivery, ["dlv"])
    {delivery, delivery_id}
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

  defp suspend!(tenant, subtenant_id \\ nil) do
    attrs = %{ground: "abuse", reason: "spam", subtenant_id: subtenant_id}
    {:ok, row} = Suspension.suspend(tenant.id, attrs, TenantFixture.actor(), "stepup-test")
    assert row["state"] == "effective"
  end

  defp lift!(tenant, subtenant_id \\ nil) do
    {:ok, row} =
      Suspension.resume(tenant.id, subtenant_id, "appeal", TenantFixture.actor(), "stepup-test")

    assert row["state"] == "lifted"
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

  defp complete_jobs!(delivery_id) do
    Repo.query!(
      """
      UPDATE relay_queue.oban_jobs SET state = 'completed', completed_at = now()
      WHERE args->>'delivery_id' = $1
      """,
      [Relay.Id.to_string(delivery_id)]
    )
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

  describe "TN-10 TN-40 pending work of a suspension" do
    test "TN-10, TN-40: an effective suspension pauses pending deliveries, never deletes them",
         ctx do
      {delivery, delivery_id} = accept!(ctx.token)
      suspend!(ctx.tenant)

      assert pause_state(ctx.tenant.live, delivery_id) == {true, "tenant.suspended", nil}
      [job] = F.delivery_jobs(delivery)
      assert Relay.Delivery.Send.perform(%Oban.Job{args: Map.delete(job, "queue")}) == :ok
      assert pause_state(ctx.tenant.live, delivery_id) == {true, "tenant.suspended", nil}
    end

    test "TN-40: lifting keeps deliveries PAUSED while the policy lattice is not ready", ctx do
      {_delivery, delivery_id} = accept!(ctx.token)
      suspend!(ctx.tenant)
      lift!(ctx.tenant)

      assert pause_state(ctx.tenant.live, delivery_id) == {true, "tenant.suspended", nil}
    end

    test "TN-40: lifting resumes through the lattice; send lifts the pause and queues a job",
         ctx do
      {_delivery, delivery_id} = accept!(ctx.token)
      suspend!(ctx.tenant)
      complete_jobs!(delivery_id)
      assert available_jobs(delivery_id) == 0

      with_lattice({:send, "lattice-test"}, fn -> lift!(ctx.tenant) end)

      assert pause_state(ctx.tenant.live, delivery_id) == {false, nil, nil}
      assert available_jobs(delivery_id) == 1
    end

    test "TN-40: a delivery the lattice skips is cancelled with its rule", ctx do
      {_delivery, delivery_id} = accept!(ctx.token)
      suspend!(ctx.tenant)

      with_lattice({:skip, "quiet_hours", "policy.quiet_hours"}, fn -> lift!(ctx.tenant) end)

      assert {_paused?, _rule, "cancelled"} = pause_state(ctx.tenant.live, delivery_id)
    end

    test "TN-10: a subtenant suspension pauses only that subtenant's deliveries", ctx do
      subtenant_id = TenantFixture.subtenant!(ctx.tenant.live)
      branch = %{"tenant" => Relay.ExternalId.encode("stn", subtenant_id)}
      {_branch_delivery, branch_id} = accept!(ctx.token, branch)
      {_other_delivery, other_id} = accept!(ctx.token)

      suspend!(ctx.tenant, subtenant_id)

      assert pause_state(ctx.tenant.live, branch_id) == {true, "subtenant.suspended", nil}
      assert pause_state(ctx.tenant.live, other_id) == {false, nil, nil}
    end
  end
end
