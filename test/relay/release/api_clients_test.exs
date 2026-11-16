defmodule Relay.Release.ApiClientsTest do
  use Relay.DataCase, async: false

  import ExUnit.CaptureIO

  alias Relay.Access.ClientStore
  alias Relay.Release.ApiClients
  alias RelayTest.TenantFixture

  defp register!(tenant, client) do
    {:ok, actor} = Relay.Actor.new(:access, "access", "access")
    id = Relay.Id.generate()
    digest = TenantFixture.digest()
    work = fn _status -> ClientStore.register(id, client, "evt_test", digest, actor) end
    assert {:ok, {:created, ^id}} = ClientStore.in_scope(tenant.live, work)
  end

  defp tenant_ref(tenant), do: Relay.ExternalId.encode("ten", tenant.id)

  defp audited?(scope, action) do
    now = DateTime.utc_now()

    sql =
      "SELECT tenant_id, environment, target_id FROM relay_fn.audit_query($1, $2, $3, NULL, 10, $4, $5, $6, $7, $8)"

    params = [
      DateTime.add(now, -3600),
      DateTime.add(now, 3600),
      action,
      TenantFixture.digest() | Relay.Actor.params(TenantFixture.actor())
    ]

    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _status -> Relay.Repo.scoped_query!(sql, params).rows end)

    Enum.any?(rows, &(List.last(&1) == "app_release"))
  end

  describe "E-99 release commands" do
    test "E-99: the release command lists and assigns a pending client on the audited path" do
      tenant = TenantFixture.tenant!()
      register!(tenant, "app_release")

      assert {:ok, %{pending: [%{access_client_id: "app_release"}]}} =
               ApiClients.pending(tenant: tenant_ref(tenant))

      opts = [
        operator: "ops@example.com",
        tenant: tenant_ref(tenant),
        environment: :test,
        client: "app_release",
        scopes: ["read", "publish"]
      ]

      assert {:ok, %{access_client_id: "app_release", environment: :test, scopes: scopes}} =
               ApiClients.assign(opts)

      assert scopes == ["publish", "read"]
      assert {:ok, %{pending: []}} = ApiClients.pending(tenant: tenant_ref(tenant))
      assert audited?(tenant.live, "api_client.assigned")
      assert audited?(tenant.test, "api_client.created")
    end

    test "E-99: the release script's encoded arguments run the same command" do
      tenant = TenantFixture.tenant!()
      register!(tenant, "app_release")

      args = [
        "assign",
        "--operator",
        "ops@example.com",
        "--tenant",
        tenant_ref(tenant),
        "--environment",
        "live",
        "--client",
        "app_release",
        "--scopes",
        "publish"
      ]

      encoded = Base.encode64(Enum.join(args, "\n") <> "\n")
      output = capture_io(fn -> send(self(), {:result, ApiClients.run(encoded)}) end)
      assert_received {:result, {:ok, %{environment: :live, scopes: ["publish"]}}}
      assert output =~ "app_release"
    end

    test "E-99: missing or invalid options are refused before anything is written" do
      tenant = TenantFixture.tenant!()
      base = [operator: "ops", tenant: tenant_ref(tenant), environment: :live, client: "app_x"]

      assert {:error, :invalid_scopes} = ApiClients.assign(Keyword.put(base, :scopes, ["admin"]))
      assert {:error, :operator_required} = ApiClients.assign(scopes: ["read"])
      assert {:error, :api_client_not_found} = ApiClients.assign([{:scopes, ["read"]} | base])
      assert {:error, :unknown_command} = capture_and_run(["remove"])
    end
  end

  defp capture_and_run(args) do
    encoded = Base.encode64(Enum.join(args, "\n"))
    capture_io(fn -> send(self(), {:run, ApiClients.run(encoded)}) end)
    assert_received {:run, result}
    result
  end
end
