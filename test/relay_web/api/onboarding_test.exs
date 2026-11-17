defmodule RelayWeb.Api.OnboardingTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @background ["Relay.Api.TestPlane.Seeder", "Relay.Delivery.Send"]

  defp run_background(scope, done \\ MapSet.new(), rounds \\ 5)
  defp run_background(_scope, _done, 0), do: :ok

  defp run_background(scope, done, rounds) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, worker, args FROM relay_queue.oban_jobs
        WHERE worker = ANY ($1) AND args->>'tenant_id' = $2
          AND state IN ('available', 'scheduled')
        ORDER BY id
        """,
        [@background, Relay.Scope.tenant_text(scope)]
      )

    case Enum.reject(rows, fn [id | _] -> MapSet.member?(done, id) end) do
      [] ->
        :ok

      pending ->
        for [id, worker, args] <- pending do
          module = Module.safe_concat([worker])
          module.perform(%Oban.Job{id: id, worker: worker, args: args, attempt: 1})
        end

        run_background(scope, MapSet.union(done, MapSet.new(pending, &hd/1)), rounds - 1)
    end
  end

  describe "X-46 onboarding acceptance" do
    test "X-46 X-35 X-36: a fresh tenant reaches its first test inbox message with one request",
         _ctx do
      tenant = TenantFixture.tenant!()
      run_background(tenant.test)

      token = F.token(tenant.test)

      request = %{
        "workflow" => "welcome",
        "to" => [%{"id" => "user-ada", "email" => "ada@example.com"}],
        "data" => %{"first_name" => "Ada"}
      }

      accepted = F.body(F.request(:post, "/v1/events", token, request), 202)
      [%{"notification_id" => notification}] = accepted["notifications"]
      run_background(tenant.test)

      inbox = F.body(F.request(:get, "/v1/test/inbox", token), 200)
      shown = Enum.find(inbox["data"], &(&1["notification_id"] == notification))

      assert shown != nil, "the first message is not in the test inbox"
      assert [_ | _] = shown["deliveries"]

      for delivery <- shown["deliveries"] do
        assert is_binary(delivery["rule_id"]), "no rule_id on #{delivery["channel"]}"
      end

      in_app = Enum.find(shown["deliveries"], &(&1["channel"] == "in_app"))
      assert %{"output" => %{} = output} = in_app["render"]
      assert output["body"] =~ "Ada"
    end
  end
end
