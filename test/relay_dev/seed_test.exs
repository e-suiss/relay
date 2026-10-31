defmodule RelayDev.SeedTest do
  use Relay.DataCase, async: false

  alias Relay.Access.Clients
  alias Relay.Access.Link
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayWeb.Auth.Access

  @scopes ~w(config kill_switch publish read subscribers)

  setup do
    :ok = Clients.reset()

    on_exit(fn ->
      Link.put(Link.snapshot(nil, FakeAccess.issuer()))
      Clients.reset()
    end)

    {:ok, report} = RelayDev.Seed.run()
    {:ok, tenant_id} = Relay.ExternalId.decode(report.tenant, ["ten"])
    %{report: report, plane: Relay.Scope.new!(tenant_id, :test)}
  end

  describe "T-65 local sample data" do
    test "T-65: running the seed again changes nothing", ctx do
      assert {:ok, again} = RelayDev.Seed.run()
      assert again == ctx.report
      assert ctx.report.workflow == "welcome"
      assert ctx.report.workflow_version == 1
    end

    test "T-65: the sample workflow is published in the test plane", ctx do
      assert {:ok, {:ok, %{"version_no" => 1}}} =
               Relay.Workflow.resolve_published(ctx.plane, "welcome")
    end

    test "T-65: the sample API client token is verified through the link to the local Access",
         ctx do
      assert Relay.Access.link_state() == :ok

      assert {:ok, principal} =
               Relay.Access.verify_server_token(RelayDev.Seed.token(),
                 audience: Access.audience(:server)
               )

      assert principal.scope.tenant_id == ctx.plane.tenant_id
      assert principal.scope.environment == :test
      assert principal.api_client_id == ctx.report.api_client
      assert Enum.sort(principal.scopes) == @scopes
    end

    test "T-65: the sample request is accepted by POST /v1/events in the test plane", ctx do
      conn = F.request(:post, "/v1/events", F.token(ctx.plane), RelayDev.Seed.sample_event())
      body = F.body(conn, 202)

      assert body["status"] == "accepted"
      assert [%{"notification_id" => "ntf_" <> _}] = body["notifications"]
    end
  end
end
