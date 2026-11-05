defmodule Relay.Channels.ProviderAccountsTest do
  use Relay.DataCase, async: false

  alias Relay.ChannelDeclarations
  alias RelayTest.TenantFixture

  defp declarations do
    {:ok, content} = ChannelDeclarations.compose()
    ChannelDeclarations.new(content, nil)
  end

  defp account(fields \\ []) do
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
  end

  defp put(scope, attrs),
    do: Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

  defp verify(scope, id, state, rule_id \\ nil) do
    Relay.Channels.verify_account(
      scope,
      id,
      state,
      rule_id,
      TenantFixture.digest(),
      TenantFixture.actor()
    )
  end

  defp sender(scope, account_id, fields \\ []) do
    attrs =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          provider_account_id: account_id,
          channel: "email",
          kind: "email_domain",
          value: "mail.example.com",
          approval_state: "approved"
        },
        Map.new(fields)
      )

    {:ok, {:created, 1}} =
      Relay.Channels.put_sender_identity(
        scope,
        attrs,
        TenantFixture.digest(),
        TenantFixture.actor()
      )

    attrs.id
  end

  defp usable(scope) do
    {:ok, {usable, _excluded}} = Relay.Channels.routes(scope, "email", declarations(), %{})
    Enum.map(usable, & &1["id"])
  end

  defp scope, do: TenantFixture.tenant!().live

  describe "C-45 MD-4 provider accounts" do
    test "C-45, OP-8: an account is created, kept, updated and guarded by its version" do
      scope = scope()
      attrs = account()

      assert {:ok, {:created, 1}} = put(scope, attrs)
      assert {:ok, {:unchanged, 1}} = put(scope, attrs)
      assert {:ok, {:updated, 2}} = put(scope, %{attrs | priority: 1})
      assert {:ok, {:version_conflict, 2}} = put(scope, Map.merge(attrs, %{expected_version: 1}))

      assert {:ok, {:not_found, nil}} =
               put(scope, Map.merge(account(), %{expected_version: 1}))

      assert {:ok, {:credential_not_found, nil}} =
               put(scope, account(ownership: "tenant", credential_ref_id: Relay.Id.generate()))
    end

    test "CH-14, INV-43, C-25: only a verified account with an approved sender identity is routed" do
      scope = scope()
      attrs = account()
      {:ok, {:created, 1}} = put(scope, attrs)
      sender(scope, attrs.id)

      assert usable(scope) == []
      assert {:ok, :changed} = verify(scope, attrs.id, "verified")
      assert {:ok, :unchanged} = verify(scope, attrs.id, "verified")
      assert usable(scope) == [attrs.id]

      assert {:ok, {:updated, 2}} = put(scope, %{attrs | provider: "other"})
      assert usable(scope) == []
    end

    test "TN-10: a suspended sender identity takes its account out of the route" do
      scope = scope()
      attrs = account()
      {:ok, {:created, 1}} = put(scope, attrs)
      {:ok, :changed} = verify(scope, attrs.id, "verified")
      identity = sender(scope, attrs.id)
      assert usable(scope) == [attrs.id]

      digest = TenantFixture.digest()
      actor = TenantFixture.actor()

      assert {:ok, :suspended} =
               Relay.Channels.suspend_sender_identity(
                 scope,
                 identity,
                 true,
                 "subscriber.suspended",
                 digest,
                 actor
               )

      assert usable(scope) == []

      assert {:ok, :resumed} =
               Relay.Channels.suspend_sender_identity(scope, identity, false, nil, digest, actor)

      assert usable(scope) == [attrs.id]
    end

    test "TN-26, TN-21: a credential rotation needs a step-up and a tenant-owned account" do
      scope = scope()
      attrs = account()
      {:ok, {:created, 1}} = put(scope, attrs)
      digest = TenantFixture.digest()
      actor = TenantFixture.actor()
      new = Relay.Id.generate()

      assert {:ok, :step_up_required} =
               Relay.Channels.rotate_credential(scope, attrs.id, new, nil, digest, actor)

      assert {:ok, :not_tenant_owned} =
               Relay.Channels.rotate_credential(scope, attrs.id, new, "stp-1", digest, actor)

      other = Relay.Id.generate()

      assert {:ok, :not_found} =
               Relay.Channels.rotate_credential(scope, other, new, "stp-1", digest, actor)
    end

    test "C-26: a channel identity needs a channel identity secret" do
      scope = scope()

      attrs = %{
        id: Relay.Id.generate(),
        channel: "push",
        kind: "apns_key",
        app_ref: "com.example.app",
        secret_ref_id: Relay.Id.generate()
      }

      assert {:ok, {:secret_not_found, nil}} =
               Relay.Channels.put_channel_identity(
                 scope,
                 attrs,
                 TenantFixture.digest(),
                 TenantFixture.actor()
               )
    end
  end

  describe "CH-11 CH-8 cleanup and alarms" do
    test "CH-11, INV-14: disabling a recipient without an active address changes nothing" do
      scope = scope()

      assert {:ok, {:not_found, nil}} =
               Relay.Channels.disable_address(
                 scope,
                 Relay.Id.generate(),
                 "email",
                 "email",
                 "channel.address_disabled"
               )
    end

    test "CH-8, INV-46: a provider code without a mapping raises the event and the alarm" do
      scope = scope()
      ref = :telemetry_test.attach_event_handlers(self(), [[:relay, :channels, :unknown_code]])

      assert {:ok, :appended} = Relay.Channels.report_unknown_code(scope, "fake", "sms", "X-1")
      assert_received {[:relay, :channels, :unknown_code], ^ref, %{count: 1}, %{provider: "fake"}}
    end

    test "C-45: the health of an account is recorded" do
      scope = scope()
      attrs = account()
      {:ok, {:created, 1}} = put(scope, attrs)

      assert {:ok, :updated} = Relay.Channels.set_account_health(scope, attrs.id, "healthy")
      assert {:ok, :unchanged} = Relay.Channels.set_account_health(scope, attrs.id, "healthy")
      missing = Relay.Id.generate()
      assert {:ok, :not_found} = Relay.Channels.set_account_health(scope, missing, "down")
    end
  end
end
