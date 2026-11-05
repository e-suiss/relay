defmodule RelayWeb.Api.MessagingTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    scope = tenant.test
    token = F.token(scope)
    external_id = "user-" <> TenantFixture.random()
    F.body(F.request(:post, "/v1/subscribers", token, %{"external_id" => external_id}), 201)
    %{scope: scope, token: token, external_id: external_id}
  end

  defp account!(scope, channel) do
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      channel: channel,
      provider: channel,
      ownership: "shared",
      role: "primary",
      priority: 0,
      processing_countries: ["US"],
      transfer_basis: "adequacy"
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

    Relay.ExternalId.encode("pva", id)
  end

  defp path(external_id, channel),
    do: "/v1/subscribers/#{external_id}/messaging_targets/#{channel}"

  describe "CH-62 conversations" do
    test "CH-62: a conversation is created, replaced and removed and never returned", ctx do
      account = account!(ctx.scope, "slack")
      body = %{"provider_account_id" => account, "conversation" => "U1"}

      created = F.body(F.request(:put, path(ctx.external_id, "slack"), ctx.token, body), 201)
      assert %{"object" => "messaging_target", "channel" => "slack"} = created
      assert created["state"] == "active"
      refute Map.has_key?(created, "conversation")

      replaced = F.body(F.request(:put, path(ctx.external_id, "slack"), ctx.token, body), 200)
      assert replaced["id"] != created["id"]

      removed = F.body(F.request(:delete, path(ctx.external_id, "slack"), ctx.token), 200)
      assert %{"state" => "disabled", "id" => id} = removed
      assert id == replaced["id"]

      missing = F.body(F.request(:delete, path(ctx.external_id, "slack"), ctx.token), 404)
      assert missing["code"] == "messaging_target_not_found"
    end

    test "CH-62: a conversation of another channel's account or of a bad form is refused", ctx do
      account = account!(ctx.scope, "slack")
      teams = %{"provider_account_id" => account, "conversation" => "U1"}

      refused = F.body(F.request(:put, path(ctx.external_id, "telegram"), ctx.token, teams), 404)
      assert refused["code"] == "provider_account_not_found"

      bad = %{"provider_account_id" => account, "conversation" => "has space"}
      invalid = F.body(F.request(:put, path(ctx.external_id, "slack"), ctx.token, bad), 422)
      assert invalid["code"] == "validation_failed"
    end
  end

  describe "CH-4 CH-62 installations and adapters" do
    test "CH-4: the adapters list their versions", ctx do
      list = F.body(F.request(:get, "/v1/channel_adapters", ctx.token), 200)
      providers = Enum.map(list["data"], & &1["provider"])
      for p <- ~w(slack teams telegram discord), do: assert(p in providers)
    end

    test "CH-62: an installation of an unknown channel identity is not found", ctx do
      body = %{
        "channel" => "slack",
        "channel_identity_id" => Relay.ExternalId.encode("chi", Relay.Id.generate())
      }

      conn = F.request(:post, "/v1/messaging_installations", ctx.token, body)
      assert F.body(conn, 404)["code"] == "channel_identity_not_found"
    end

    test "CH-62: the redirect with a state that does not unseal is refused" do
      conn = F.request(:get, "/v1/messaging_installations/callback?code=c&state=bad", nil)
      assert F.body(conn, 400)["code"] == "messaging_install_state_invalid"
    end
  end

  describe "CH-62 WH-49 inbound endpoint" do
    test "CH-62: an inbound request of an unknown identity or channel is not found", ctx do
      tenant = Relay.ExternalId.encode("ten", ctx.scope.tenant_id)
      identity = Relay.ExternalId.encode("chi", Relay.Id.generate())

      for channel <- ["slack", "sms"] do
        url = "/inbound/v1/#{channel}/#{tenant}/test/#{identity}"
        conn = Api.conn(:post, url, "{}", [{"content-type", "application/json"}])
        assert Api.call(conn, RelayWeb.Router).status == 404
      end
    end
  end
end
