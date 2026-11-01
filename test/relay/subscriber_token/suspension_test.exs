defmodule Relay.SubscriberToken.SuspensionTest do
  use Relay.DataCase, async: false

  alias Relay.Operators.SubscriberSuspension
  alias RelayTest.Api
  alias RelayTest.FakeAccess
  alias RelayTest.TenantFixture
  alias RelayWeb.Auth.Subscriber

  @grant "urn:ietf:params:oauth:grant-type:token-exchange"
  @subject_type "urn:ietf:params:oauth:token-type:access_token"

  setup do
    :ok = FakeAccess.install!()
    tenant = TenantFixture.tenant!()
    app = FakeAccess.client!(tenant.test, ["read"])
    %{scope: tenant.test, access_tenant: tenant.attrs.access_tenant_id, app: app}
  end

  defp exchange(ctx, sub) do
    token = FakeAccess.user_token(ctx.access_tenant, ctx.app, sub)

    form = %{
      "grant_type" => @grant,
      "subject_token" => token,
      "subject_token_type" => @subject_type
    }

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    :post
    |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
    |> Api.call(RelayWeb.Router)
  end

  describe "TN-73 API-45 subscriber endpoints of a suspended subscriber" do
    test "TN-73, API-45: a suspended subscriber gets no token and its tokens no longer verify",
         ctx do
      sub = "pairwise-" <> FakeAccess.random()
      first = exchange(ctx, sub)
      assert first.status == 200
      body = Jason.decode!(first.resp_body)
      {:ok, id} = Relay.ExternalId.decode(body["subscriber_id"], ["sub"])
      assert {:ok, _verified} = Subscriber.verify(body["access_token"])

      {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, id, "abuse", TenantFixture.actor())

      refused = exchange(ctx, sub)
      assert refused.status == 403
      Api.assert_contract(refused)
      assert Jason.decode!(refused.resp_body)["code"] == "auth_subscriber_suspended"

      assert {:error, %Relay.Error{code: :auth_subscriber_suspended}} =
               Subscriber.verify(body["access_token"])

      {:ok, _view} = SubscriberSuspension.resume(ctx.scope, id, "appeal", TenantFixture.actor())

      assert exchange(ctx, sub).status == 200
      assert {:ok, _verified} = Subscriber.verify(body["access_token"])
    end

    test "TN-73: another subscriber of the tenant is not affected", ctx do
      sub = "pairwise-" <> FakeAccess.random()
      body = Jason.decode!(exchange(ctx, sub).resp_body)
      {:ok, id} = Relay.ExternalId.decode(body["subscriber_id"], ["sub"])
      {:ok, _view} = SubscriberSuspension.suspend(ctx.scope, id, "abuse", TenantFixture.actor())

      assert exchange(ctx, "pairwise-" <> FakeAccess.random()).status == 200
    end
  end
end
