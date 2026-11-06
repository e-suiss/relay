defmodule RelayWeb.Api.WhatsappWebhookTest do
  use Relay.DataCase, async: false

  alias RelayTest.Api
  alias RelayTest.TenantFixture

  defp path(id), do: "/v1/inbound/whatsapp/" <> Relay.Id.to_string(id)

  defp challenge(id, token) do
    query = URI.encode_query(%{"hub.mode" => "subscribe", "hub.verify_token" => token})
    conn = Api.conn(:get, path(id) <> "?" <> query <> "&hub.challenge=42")
    Api.call(conn, RelayWeb.Router)
  end

  defp notify(id, headers) do
    body = ~s({"object":"whatsapp_business_account","entry":[]})
    Api.call(Api.json(:post, path(id), nil, body, headers), RelayWeb.Router)
  end

  defp code(conn, status) do
    assert conn.status == status, conn.resp_body
    Jason.decode!(conn.resp_body)["code"]
  end

  defp account(settings) do
    scope = TenantFixture.tenant!().live

    attrs = %{
      id: Relay.Id.generate(),
      channel: "whatsapp",
      provider: "whatsapp_cloud",
      ownership: "shared",
      role: "primary",
      priority: 0,
      in_installation: false,
      processing_countries: ["US"],
      transfer_basis: "explicit_consent",
      settings: settings
    }

    digest = TenantFixture.digest()
    {:ok, {:created, 1}} = Relay.Channels.put_account(scope, attrs, digest, TenantFixture.actor())
    attrs.id
  end

  describe "CH-60 WhatsApp webhook route" do
    test "CH-60: an unknown account is not found on both methods" do
      id = Relay.Id.generate()
      assert code(challenge(id, "t"), 404) == "provider_account_not_found"

      signed = [{"x-hub-signature-256", "sha256=00"}]
      assert code(notify(id, signed), 404) == "provider_account_not_found"
    end

    test "CH-60, T-40: an unsigned notification is refused before the account is read" do
      assert code(notify(Relay.Id.generate(), []), 401) == "auth_missing_credentials"
    end

    test "CH-60, TN-26: an account without its secret references cannot be verified" do
      id = account(%{"phone_number_id" => "1065"})
      assert code(challenge(id, "t"), 401) == "auth_invalid_token"

      signed = [{"x-hub-signature-256", "sha256=00"}]
      assert code(notify(id, signed), 401) == "auth_invalid_token"
    end
  end
end
