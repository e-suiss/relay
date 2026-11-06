defmodule RelayWeb.Api.ChannelSurfaceTest do
  use Relay.DataCase, async: false

  alias Relay.Datasets
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @datasets ["channel_event_evidence", "channel_parameters"]

  defp forget do
    for name <- @datasets,
        do: :ok = Datasets.Cache.invalidate(Datasets.Cache, {Datasets.installation_scope(), name})
  end

  setup do
    forget()
    {:ok, _report} = Datasets.load_package(TenantFixture.actor())
    on_exit(&forget/0)

    tenant = TenantFixture.tenant!()
    token = F.token(tenant.live)
    F.workflow!(tenant.live, token, "order-shipped")
    %{tenant: tenant, scope: tenant.live, token: token}
  end

  defp send_event(token, body), do: F.request(:post, "/v1/events", token, body)

  defp event(fields \\ %{}) do
    Map.merge(
      %{
        "workflow" => "order-shipped",
        "to" => [%{"id" => "user-" <> TenantFixture.random(), "email" => "ayse@example.com"}],
        "data" => %{"order" => "A-1"}
      },
      fields
    )
  end

  defp account!(scope, fields \\ []) do
    attrs =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          channel: "email",
          provider: "fake",
          ownership: "shared",
          role: "primary",
          priority: 0,
          in_installation: true,
          transfer_basis: "none"
        },
        Map.new(fields)
      )

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

    sender = %{
      id: Relay.Id.generate(),
      provider_account_id: attrs.id,
      channel: attrs.channel,
      kind: "email_domain",
      value: "mail.example.com",
      approval_state: "approved"
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_sender_identity(
        scope,
        sender,
        TenantFixture.digest(),
        TenantFixture.actor()
      )

    {:ok, :changed} =
      Relay.Channels.verify_account(
        scope,
        attrs.id,
        "verified",
        nil,
        TenantFixture.digest(),
        TenantFixture.actor()
      )

    attrs.id
  end

  defp providers(scope, notification) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          "SELECT provider FROM relay.deliveries WHERE notification_id = $1",
          [notification]
        ).rows
      end)

    List.flatten(rows)
  end

  defp internal("ntf_" <> _ = external) do
    {:ok, id} = Relay.ExternalId.decode(external, ["ntf"])
    id
  end

  describe "CH-72 X-26 simulated results" do
    test "CH-72, X-26: the test plane lists the fake provider's table from its one module",
         ctx do
      body = F.body(F.request(:get, "/v1/test/simulated-results", F.token(ctx.tenant.test)), 200)

      assert body["object"] == "list"
      assert body["has_more"] == false
      assert length(body["data"]) == 15

      assert Enum.map(body["data"], & &1["result"]) == Relay.Channels.Simulated.results()

      assert %{"email" => "hard_bounce@sim.relay.test", "phone" => "+990555000004"} =
               Enum.at(body["data"], 3)
    end

    test "CH-72: a live client gets auth_environment_mismatch", ctx do
      conn = F.request(:get, "/v1/test/simulated-results", ctx.token)
      assert F.body(conn, 403)["code"] == "auth_environment_mismatch"
    end

    test "CH-72, X-25: the live plane refuses a simulated address at the API", ctx do
      to = [%{"id" => "user-" <> TenantFixture.random(), "email" => "hard_bounce@sim.relay.test"}]

      assert F.body(send_event(ctx.token, event(%{"to" => to})), 422)["code"] ==
               "recipient_invalid"

      phone = [%{"id" => "user-" <> TenantFixture.random(), "phone" => "+990555000004"}]

      assert F.body(send_event(ctx.token, event(%{"to" => phone})), 422)["code"] ==
               "recipient_invalid"
    end
  end

  describe "API-23 provider and sender overrides" do
    test "API-23: a provider without a verified account is refused", ctx do
      overrides = %{"email" => %{"provider" => "fake"}}
      conn = send_event(ctx.token, event(%{"overrides" => overrides}))
      assert F.body(conn, 403)["code"] == "channel_not_configured"
    end

    test "API-23: a verified provider narrows the delivery's route", ctx do
      account!(ctx.scope)
      overrides = %{"email" => %{"provider" => "fake"}}
      body = F.body(send_event(ctx.token, event(%{"overrides" => overrides})), 202)
      [%{"notification_id" => notification}] = body["notifications"]

      assert providers(ctx.scope, internal(notification)) == ["fake"]
    end

    test "API-23: a sender address must lie on a verified domain", ctx do
      account!(ctx.scope)

      outside = %{"email" => %{"from" => "news@other.example.com"}}
      conn = send_event(ctx.token, event(%{"overrides" => outside}))
      assert F.body(conn, 403)["code"] == "channel_not_configured"

      inside = %{"email" => %{"from" => "news@mail.example.com"}}
      assert F.body(send_event(ctx.token, event(%{"overrides" => inside})), 202)
    end

    test "API-23, TN-58: the tenant default applies and a domestic-only policy drops it", ctx do
      account!(ctx.scope,
        in_installation: false,
        processing_countries: ["US"],
        transfer_basis: "adequacy"
      )

      put = fn key, value ->
        change = %{
          key: key,
          value: value,
          expected_version: nil,
          record_digest: TenantFixture.digest()
        }

        {:ok, _} = Relay.Tenancy.put_setting(ctx.scope, change, TenantFixture.actor())
      end

      put.("overrides.email.provider", "fake")
      body = F.body(send_event(ctx.token, event()), 202)
      [%{"notification_id" => notification}] = body["notifications"]
      assert providers(ctx.scope, internal(notification)) == ["fake"]

      put.("channels.domestic_only", "TR")
      conn = send_event(ctx.token, event())
      assert F.body(conn, 403)["code"] == "channel_not_configured"
    end
  end
end
