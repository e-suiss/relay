defmodule Relay.Channels.SettingsCheckJobTest do
  use Relay.DataCase, async: false

  alias Relay.Channels.Email.Esp
  alias Relay.Channels.Live
  alias Relay.Channels.Live.SettingsCheck
  alias Relay.Repo
  alias RelayTest.IngestFixture, as: F
  alias RelayTest.TenantFixture

  @state "SELECT verification_state, verification_rule_id, health FROM relay.provider_accounts WHERE id = $1"
  @outbox "SELECT payload FROM relay.outbox_events WHERE event_type = $1"
  @mismatched "provider_account.settings_mismatched"

  defp sql!(scope, sql, params) do
    {:ok, rows} = Repo.in_scope(scope, fn _status -> Repo.scoped_query!(sql, params).rows end)
    rows
  end

  defp state(scope, id), do: hd(sql!(scope, @state, [id]))

  defp credential!(scope, value) do
    var = "RELAY_TEST_SETTINGS_" <> String.upcase(TenantFixture.random())
    System.put_env(var, Jason.encode!(value))
    on_exit(fn -> System.delete_env(var) end)
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: :provider_credential,
      ref: "${#{var}}",
      ref_version: 1,
      record_digest: TenantFixture.digest()
    }

    {:ok, :created} = Relay.Secrets.register(scope, attrs, TenantFixture.actor())
    id
  end

  defp account!(scope, provider, fields \\ []) do
    attrs =
      Map.merge(
        %{
          id: Relay.Id.generate(),
          channel: "email",
          provider: provider,
          ownership: "tenant",
          credential_ref_id: credential!(scope, %{"server_token" => TenantFixture.random()}),
          role: "primary",
          priority: 0,
          in_installation: true,
          transfer_basis: "none"
        },
        Map.new(fields)
      )

    {:ok, {:created, 1}} =
      Relay.Channels.put_account(scope, attrs, TenantFixture.digest(), TenantFixture.actor())

    attrs.id
  end

  defp verify!(scope, id) do
    {:ok, :changed} =
      Relay.Channels.verify_account(
        scope,
        id,
        "verified",
        nil,
        TenantFixture.digest(),
        TenantFixture.actor()
      )
  end

  defp perform(scope, id, attempt \\ 1) do
    args = Map.put(Relay.Scope.to_job_args(scope), "provider_account_id", Relay.Id.to_string(id))
    SettingsCheck.perform(%Oban.Job{args: args, attempt: attempt, max_attempts: 5})
  end

  defp request(scope, id) do
    actor = TenantFixture.actor()
    Repo.in_scope(scope, fn _status -> Live.request_settings_check(scope, id, actor) end)
  end

  defp server(type), do: Req.Test.stub(Esp, &Req.Test.json(&1, %{"DeliveryType" => type}))

  defp scope, do: TenantFixture.tenant!().live

  describe "CH-14 CH-52 provider settings check" do
    test "CH-14: asking for a verification marks the account pending and queues the check" do
      scope = scope()
      id = account!(scope, "postmark")

      assert request(scope, id) == {:ok, :pending}
      assert ["pending", nil, _health] = state(scope, id)

      assert [[Relay.Id.to_string(id)]] ==
               F.jobs("Relay.Channels.Live.SettingsCheck", scope, "provider_account_id")

      assert request(scope, Relay.Id.generate()) == {:ok, :not_found}
    end

    test "CH-14: a successful check verifies the account and records its health" do
      scope = scope()
      id = account!(scope, "postmark")
      server("Live")

      assert perform(scope, id) == :ok
      assert ["verified", nil, "healthy"] = state(scope, id)
      assert sql!(scope, @outbox, [@mismatched]) == []
    end

    test "CH-52: a mismatch fails the account with its rule and appends its event" do
      scope = scope()
      id = account!(scope, "postmark")
      server("Sandbox")

      assert perform(scope, id) == :ok
      assert ["failed", "channel.provider_settings_mismatch", "degraded"] = state(scope, id)

      assert [[payload]] = sql!(scope, @outbox, [@mismatched])

      assert payload == %{
               "provider_account_id" => Relay.ExternalId.encode("pva", id),
               "provider" => "postmark",
               "channel" => "email",
               "failure_class" => "sender_config",
               "rule_id" => "channel.provider_settings_mismatch",
               "setting" => "delivery_type",
               "expected" => "Live",
               "actual" => "Sandbox"
             }
    end

    test "CH-14: an adapter without a settings check fails closed" do
      scope = scope()
      id = account!(scope, "teams", channel: "teams")

      assert perform(scope, id) == :ok
      assert ["failed", "channel.provider_check_unsupported", _health] = state(scope, id)
    end

    test "CH-14, T-26: an unreachable provider is retried, then fails the account" do
      scope = scope()
      id = account!(scope, "postmark")
      Req.Test.stub(Esp, &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, "provider_unavailable"} = perform(scope, id)
      assert ["unverified", nil, _health] = state(scope, id)

      assert perform(scope, id, 5) == :ok
      assert ["failed", "channel.provider_check_unavailable", "down"] = state(scope, id)
    end

    test "CH-52: the periodic check drops a mismatched account and never verifies one again" do
      scope = scope()
      kept = account!(scope, "postmark")
      dropped = account!(scope, "postmark")
      failed = account!(scope, "postmark")
      verify!(scope, kept)
      verify!(scope, dropped)

      server("Live")
      assert SettingsCheck.sweep(3_600, 20, 5) >= 2
      assert ["verified", nil, "healthy"] = state(scope, kept)
      assert ["unverified", nil, _health] = state(scope, failed)

      server("Sandbox")
      assert SettingsCheck.check(scope, row!(scope, dropped), :recheck, true) == :ok
      assert ["failed", "channel.provider_settings_mismatch", "degraded"] = state(scope, dropped)
      assert ["verified", nil, "healthy"] = state(scope, kept)
      assert [[_payload]] = sql!(scope, @outbox, [@mismatched])

      server("Live")
      assert SettingsCheck.sweep(0, 20, 5) >= 1
      assert ["failed", "channel.provider_settings_mismatch", _health] = state(scope, dropped)
    end
  end

  defp row!(scope, id) do
    {:ok, %{} = row} = Relay.Channels.provider_account(scope, id)
    row
  end
end
