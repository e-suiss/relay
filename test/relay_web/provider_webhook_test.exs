defmodule RelayWeb.ProviderWebhookTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.IngestFixture
  alias RelayTest.TenantFixture

  defp post(id, body, query \\ "") do
    path = "/inbound/v1/providers/" <> id <> query
    conn = Api.conn(:post, path, body, [{"content-type", "application/json"}])
    Api.call(conn, RelayWeb.Router)
  end

  defp secret!(scope, value) do
    var = "RELAY_TEST_WEBHOOK_" <> String.upcase(TenantFixture.random())
    System.put_env(var, value)
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: :webhook_signing,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: TenantFixture.digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    Relay.Id.to_string(id)
  end

  defp account!(scope, settings) do
    attrs = %{
      id: Relay.Id.generate(),
      channel: "sms",
      provider: "verimor",
      ownership: "shared",
      role: "primary",
      priority: 0,
      in_installation: true,
      transfer_basis: "none",
      settings: settings
    }

    digest = TenantFixture.digest()
    {:ok, {:created, 1}} = Relay.Channels.put_account(scope, attrs, digest, TenantFixture.actor())
    Relay.Id.to_string(attrs.id)
  end

  defp report do
    Jason.encode!([
      %{"message_id" => 5, "status" => "DELIVERED", "message_custom_id" => "dlv-unknown"}
    ])
  end

  describe "WH-49 provider webhook route" do
    test "WH-49: an unknown account or a malformed id is not found" do
      assert post(Relay.Id.to_string(Relay.Id.generate()), report()).status == 404
      assert post("nothing", report()).status == 404
    end

    test "WH-49, TN-26: an account without a verification secret cannot be verified" do
      tenant = TenantFixture.tenant!()
      TenantFixture.keys!(tenant.live)
      id = account!(tenant.live, %{})

      conn = post(id, report(), "?token=t")
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end

    test "WH-49, T-40: a verified request is answered 200 once its receipt and job are committed" do
      tenant = TenantFixture.tenant!()
      TenantFixture.keys!(tenant.live)
      id = account!(tenant.live, %{"webhook_secret_ref_id" => secret!(tenant.live, "token-1")})
      worker = "Relay.Channels.Live.ReceiptWorker"

      assert post(id, report(), "?token=token-2").status == 401
      assert IngestFixture.jobs(worker, tenant.live, "receipt_ids") == []

      conn = post(id, report(), "?token=token-1")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{}
      assert [[_ids]] = IngestFixture.jobs(worker, tenant.live, "receipt_ids")

      assert post(id, report(), "?token=token-1").status == 200
      assert [[_ids]] = IngestFixture.jobs(worker, tenant.live, "receipt_ids")
    end
  end
end
