defmodule Relay.SubscriberToken.ExchangeTest do
  use Relay.DataCase, async: false

  import Plug.Conn

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
    access_tenant = tenant.attrs.access_tenant_id
    %{tenant: tenant, access_tenant: access_tenant, app: app}
  end

  defp user_token(ctx, sub \\ "pairwise-" <> FakeAccess.random()),
    do: FakeAccess.user_token(ctx.access_tenant, ctx.app, sub)

  defp exchange(form, headers \\ []) do
    headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]

    :post
    |> Api.conn("/v1/subscriber/token", URI.encode_query(form), headers)
    |> Api.call(RelayWeb.Router)
  end

  defp form(token, extra \\ %{}) do
    Map.merge(
      %{"grant_type" => @grant, "subject_token" => token, "subject_token_type" => @subject_type},
      extra
    )
  end

  defp payload(token) do
    [_header, claims, _signature] = String.split(token, ".")
    claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  describe "E-24 TN-25 token exchange" do
    test "E-24, TN-25, API-79 (9): an Access token becomes a short-lived subscriber token for the pairwise sub",
         ctx do
      conn = exchange(form(user_token(ctx)))

      assert conn.status == 200
      Api.assert_contract(conn)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "idempotency-replayed") == []

      body = Jason.decode!(conn.resp_body)
      assert body["scope"] == "inbox:read inbox:write preferences"
      assert body["environment"] == "test"
      assert body["expires_in"] == 900
      assert "sub_" <> _ = body["subscriber_id"]

      assert {:ok, verified} = Subscriber.verify(body["access_token"])
      assert verified.scope == ctx.tenant.test
      assert Relay.ExternalId.encode("sub", verified.subscriber_id) == body["subscriber_id"]
      assert verified.scopes == ["inbox:read", "inbox:write", "preferences"]

      claims = payload(body["access_token"])
      assert claims["env"] == "test"
      refute Enum.any?(Map.values(claims), &(&1 == Relay.Scope.tenant_text(ctx.tenant.test)))
      refute body["access_token"] =~ Relay.Scope.tenant_text(ctx.tenant.test)
    end

    test "E-24, API-21: the same pairwise sub is the same subscriber; another sub is another",
         ctx do
      sub = "pairwise-" <> FakeAccess.random()
      first = Jason.decode!(exchange(form(user_token(ctx, sub))).resp_body)
      second = Jason.decode!(exchange(form(user_token(ctx, sub))).resp_body)
      other = Jason.decode!(exchange(form(user_token(ctx))).resp_body)

      assert first["subscriber_id"] == second["subscriber_id"]
      refute other["subscriber_id"] == first["subscriber_id"]
    end

    test "API-79 (9), API-45, API-46: the requested scopes are a subset of the five subscriber scopes",
         ctx do
      scope = "devices:write presence:write inbox:read"
      conn = exchange(form(user_token(ctx), %{"scope" => scope}))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["scope"] == scope

      conn = exchange(form(user_token(ctx), %{"scope" => "inbox:read admin"}))
      assert conn.status == 422
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["error"] == "invalid_scope"
    end

    test "API-79 (2): the exchange takes no Idempotency-Key and never stores its response", ctx do
      token = user_token(ctx)
      key = {"idempotency-key", "exchange-key-1"}
      first = exchange(form(token), [key])
      second = exchange(form(token), [key])

      assert first.status == 200 and second.status == 200
      assert get_resp_header(second, "idempotency-replayed") == []

      refute Jason.decode!(first.resp_body)["access_token"] ==
               Jason.decode!(second.resp_body)["access_token"]
    end

    test "API-79 (4), TN-25: tenant and environment come from the Access client registration, never from the request",
         ctx do
      live_app = FakeAccess.client!(ctx.tenant.live, ["read"])
      token = FakeAccess.user_token(ctx.access_tenant, live_app, "pairwise-live")
      conn = exchange(form(token))

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["environment"] == "live"

      conn = exchange(form(user_token(ctx), %{"tenant" => "ten_x", "environment" => "live"}))
      assert conn.status == 422
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["code"] == "unknown_field"
    end
  end

  describe "E-25 IN-41 credentials" do
    test "E-25, IN-41: an Access token is never accepted as a subscriber token", ctx do
      server = FakeAccess.server_token(ctx.access_tenant, ctx.app, "read")

      for token <- [server, user_token(ctx), "not.a.token"] do
        assert {:error, %Relay.Error{code: :auth_invalid_token}} = Subscriber.verify(token)
      end
    end

    test "API-45, E-25: a server API token or an invalid subject token is refused with the OAuth error member",
         ctx do
      server = FakeAccess.server_token(ctx.access_tenant, ctx.app, "read")
      unknown = FakeAccess.user_token(ctx.access_tenant, "app_unknown", "pairwise-1")

      for token <- [server, unknown, user_token(ctx) <> "x"] do
        conn = exchange(form(token))
        assert conn.status == 401
        Api.assert_contract(conn)
        body = Jason.decode!(conn.resp_body)
        assert %{"code" => "auth_invalid_token", "error" => "invalid_request"} = body
      end

      conn = exchange(form(user_token(ctx), %{"grant_type" => "client_credentials"}))
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] == "unsupported_grant_type"
    end

    test "TN-10, INV-42: a suspended tenant gets no subscriber token", ctx do
      change = %{
        status: "suspended",
        reason: "abuse",
        expected_version: nil,
        record_digest: TenantFixture.digest()
      }

      {:ok, {:changed, _}} =
        Relay.Tenancy.set_tenant_status(ctx.tenant.live, change, TenantFixture.actor())

      :ets.delete_all_objects(Relay.Access.Clients)
      conn = exchange(form(user_token(ctx)))

      assert conn.status == 403
      Api.assert_contract(conn)
      assert Jason.decode!(conn.resp_body)["code"] == "auth_tenant_suspended"
    end
  end

  describe "E-75 availability" do
    test "E-75: when Access cannot be reached no subscriber token is issued and the error is visible",
         ctx do
      assert {:error, _} = Relay.Access.refresh(http: [plug: {FakeAccess, down: true}])
      conn = exchange(form(user_token(ctx)))

      assert conn.status == 503
      Api.assert_contract(conn)
      assert [_] = get_resp_header(conn, "retry-after")
      refute Map.has_key?(Jason.decode!(conn.resp_body), "error")
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end
end
