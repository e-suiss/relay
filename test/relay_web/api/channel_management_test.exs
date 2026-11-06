defmodule RelayWeb.Api.ChannelManagementTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Store
  alias RelayTest.Api
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  setup do
    tenant = TenantFixture.tenant!()
    %{scope: tenant.live, other: tenant.test, token: F.token(tenant.live)}
  end

  defp patch(token, path, body, version) do
    :patch
    |> Api.conn(path, Jason.encode!(body), [
      {"content-type", "application/merge-patch+json"},
      {"authorization", "Bearer " <> token},
      {"if-match", ~s("#{version}")},
      F.key()
    ])
    |> Api.call(RelayWeb.Router)
  end

  defp secret!(scope, kind) do
    var = "RELAY_TEST_CHANNELS_" <> String.upcase(TenantFixture.random())
    System.put_env(var, "secret-" <> TenantFixture.random())
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()
    attrs = %{id: id, kind: kind, ref: "${#{var}}", ref_version: 1, record_digest: digest()}
    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    id
  end

  defp digest, do: TenantFixture.digest()

  defp account!(scope, fields \\ %{}) do
    id = Relay.Id.generate()

    attrs =
      Map.merge(
        %{
          id: id,
          channel: "email",
          provider: "fake",
          ownership: "shared",
          role: "primary",
          priority: 0,
          in_installation: true,
          transfer_basis: "none",
          settings: %{"region" => "eu"}
        },
        fields
      )

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, digest(), TenantFixture.actor())

    id
  end

  defp identity!(scope) do
    secret_id = secret!(scope, :channel_identity)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      channel: "slack",
      kind: "slack_app",
      app_ref: "A" <> TenantFixture.random(),
      secret_ref_id: secret_id
    }

    {:ok, {:created, 1}} =
      Relay.Channels.put_channel_identity(scope, attrs, digest(), TenantFixture.actor())

    {id, secret_id}
  end

  defp pva(id), do: Relay.ExternalId.encode("pva", id)

  describe "C-45 provider accounts on the server API" do
    test "C-45, INV-51: an account is listed and read with its credential fingerprint", ctx do
      credential = secret!(ctx.scope, :provider_credential)
      id = account!(ctx.scope, %{ownership: "tenant", credential_ref_id: credential})

      list = F.request(:get, "/v1/provider_accounts", ctx.token)
      assert [%{"id" => listed} = row] = F.body(list, 200)["data"]
      assert listed == pva(id)
      assert %{"fingerprint" => fingerprint, "version" => 1} = row["credential"]
      assert row["credential"]["state"] == "active"
      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      refute list.resp_body =~ "RELAY_TEST_CHANNELS_"

      conn = F.request(:get, "/v1/provider_accounts/" <> pva(id), ctx.token)
      assert F.body(conn, 200)["verification_state"] == "unverified"
      assert Plug.Conn.get_resp_header(conn, "etag") == [~s("1")]
    end

    test "CH-14, T-59 (7): a settings change under If-Match resets the verification", ctx do
      id = account!(ctx.scope)

      actor = TenantFixture.actor()
      verified = Relay.Channels.verify_account(ctx.scope, id, "verified", nil, digest(), actor)
      assert verified == {:ok, :changed}

      path = "/v1/provider_accounts/" <> pva(id)
      stale = F.body(patch(ctx.token, path, %{"priority" => 3}, 1), 412)
      assert stale["code"] == "precondition_failed"

      body = F.body(patch(ctx.token, path, %{"priority" => 3}, 2), 200)
      assert %{"priority" => 3, "verification_state" => "verified", "version" => 3} = body

      body = F.body(patch(ctx.token, path, %{"settings" => %{"region" => "us"}}, 3), 200)
      assert %{"settings" => %{"region" => "us"}, "verification_state" => "unverified"} = body
    end

    test "CH-6: a provider outside the installation names its processing countries", ctx do
      path = "/v1/provider_accounts/" <> pva(account!(ctx.scope))
      body = F.body(patch(ctx.token, path, %{"in_installation" => false}, 1), 422)
      assert [%{"pointer" => "/processing_countries"}] = body["errors"]

      patched = %{"in_installation" => false, "processing_countries" => ["DE"]}
      assert F.body(patch(ctx.token, path, patched, 1), 200)["processing_countries"] == ["DE"]
    end

    test "C-45: an archived account cannot change and leaves the route", ctx do
      id = account!(ctx.scope)

      {:ok, {:archived, 2}} =
        Relay.Channels.archive_account(ctx.scope, id, digest(), TenantFixture.actor())

      path = "/v1/provider_accounts/" <> pva(id)
      assert F.body(F.request(:get, path, ctx.token), 200)["state"] == "archived"
      archived = F.body(patch(ctx.token, path, %{"priority" => 1}, 2), 409)
      assert archived["code"] == "provider_account_archived"

      {:ok, accounts} = Relay.Repo.in_scope(ctx.scope, fn _status -> Store.accounts("email") end)

      refute Enum.any?(accounts, &(&1["id"] == id))
    end

    test "API-76: another environment's account is not found", ctx do
      path = "/v1/provider_accounts/" <> pva(account!(ctx.other))
      assert F.body(F.request(:get, path, ctx.token), 404)["code"] == "provider_account_not_found"
    end

    test "CH-14, CH-52: asking for a verification marks the account pending and queues its check",
         ctx do
      id = account!(ctx.scope)
      path = "/v1/provider_accounts/" <> pva(id) <> "/verify"

      body = F.body(F.request(:post, path, ctx.token), 202)
      assert %{"id" => listed, "verification_state" => "pending", "version" => 2} = body
      assert listed == pva(id)

      assert [[Relay.Id.to_string(id)]] ==
               F.jobs("Relay.Channels.Live.SettingsCheck", ctx.scope, "provider_account_id")

      missing = "/v1/provider_accounts/" <> pva(Relay.Id.generate()) <> "/verify"
      not_found = F.body(F.request(:post, missing, ctx.token), 404)
      assert not_found["code"] == "provider_account_not_found"
    end

    test "CH-14: a verified account stays verified and an archived one is refused", ctx do
      id = account!(ctx.scope)
      actor = TenantFixture.actor()
      verified = Relay.Channels.verify_account(ctx.scope, id, "verified", nil, digest(), actor)
      assert verified == {:ok, :changed}
      path = "/v1/provider_accounts/" <> pva(id) <> "/verify"

      body = F.body(F.request(:post, path, ctx.token), 202)
      assert %{"verification_state" => "verified", "version" => 2} = body

      {:ok, {:archived, _version}} =
        Relay.Channels.archive_account(ctx.scope, id, digest(), actor)

      refused = F.body(F.request(:post, path, ctx.token), 409)
      assert refused["code"] == "provider_account_archived"
    end
  end

  describe "C-25 sender identities on the server API" do
    test "C-25: a sender identity starts pending, changes under If-Match and is archived", ctx do
      create = %{
        "provider_account_id" => pva(account!(ctx.scope)),
        "kind" => "email_domain",
        "value" => "mail.example.com"
      }

      conn = F.request(:post, "/v1/sender_identities", ctx.token, create)
      body = F.body(conn, 201)
      assert %{"approval_state" => "pending", "channel" => "email", "state" => "active"} = body
      path = "/v1/sender_identities/" <> body["id"]
      assert Plug.Conn.get_resp_header(conn, "location") == [path]

      assert F.body(F.request(:post, "/v1/sender_identities", ctx.token, create), 409)["code"] ==
               "resource_conflict"

      assert F.body(patch(ctx.token, path, %{"country" => "TR"}, 1), 200)["country"] == "TR"

      archived = F.body(F.request(:post, path <> "/archive", ctx.token), 200)
      assert %{"state" => "archived", "version" => 3} = archived
      assert F.body(F.request(:post, path <> "/archive", ctx.token), 200)["version"] == 3
      refused = F.body(patch(ctx.token, path, %{"country" => nil}, 3), 409)
      assert refused["code"] == "sender_identity_archived"
    end

    test "C-25: an archived approved identity is no longer a sender", ctx do
      id = account!(ctx.scope)
      sender = Relay.Id.generate()

      attrs = %{
        id: sender,
        provider_account_id: id,
        channel: "email",
        kind: "email_domain",
        value: "send.example.com",
        approval_state: "approved"
      }

      {:ok, {:created, 1}} =
        Relay.Channels.put_sender_identity(ctx.scope, attrs, digest(), TenantFixture.actor())

      senders = fn ->
        Relay.Repo.in_scope(ctx.scope, fn _status -> Store.senders([id]) end)
      end

      assert {:ok, [_]} = senders.()
      path = "/v1/sender_identities/" <> Relay.ExternalId.encode("snd", sender)
      F.body(F.request(:post, path <> "/archive", ctx.token), 200)
      assert {:ok, []} = senders.()
    end

    test "C-25: an unknown provider account is not found", ctx do
      create = %{
        "provider_account_id" => pva(Relay.Id.generate()),
        "kind" => "sms_sender",
        "value" => "RELAY"
      }

      assert F.body(F.request(:post, "/v1/sender_identities", ctx.token, create), 404)["code"] ==
               "provider_account_not_found"
    end
  end

  describe "C-26 channel identities on the server API" do
    test "C-26, TN-26 (5): an app_ref changes and retiring retires the unused secret", ctx do
      {id, secret_id} = identity!(ctx.scope)
      path = "/v1/channel_identities/" <> Relay.ExternalId.encode("chi", id)

      body = F.body(F.request(:get, path, ctx.token), 200)
      assert %{"secret" => %{"state" => "active"}, "state" => "active"} = body

      assert F.body(patch(ctx.token, path, %{"app_ref" => "A-new"}, 1), 200)["app_ref"] == "A-new"

      retired = F.body(F.request(:post, path <> "/archive", ctx.token), 200)
      assert %{"state" => "retired", "secret" => %{"state" => "retired"}} = retired
      assert {:ok, %{state: :retired}} = Relay.Secrets.get(ctx.scope, secret_id)
    end

    test "C-26: another identity's app_ref is a conflict", ctx do
      {first, _secret} = identity!(ctx.scope)
      {second, _secret} = identity!(ctx.scope)
      {:ok, taken} = Relay.Channels.get_managed(ctx.scope, :channel_identity, first)
      path = "/v1/channel_identities/" <> Relay.ExternalId.encode("chi", second)
      body = F.body(patch(ctx.token, path, %{"app_ref" => taken["app_ref"]}, 1), 409)
      assert body["code"] == "resource_conflict"
    end
  end
end
