defmodule Relay.TenantLifecycle.KeyCustodyTest do
  use Relay.DataCase, async: false

  alias Relay.Repo
  alias Relay.Tenancy.KeyCache
  alias Relay.Tenancy.KeyCustody
  alias Relay.Tenancy.Keyring
  alias RelayTest.TenantFixture

  @actor %Relay.Actor{
    kind: :installation_operator,
    ref: "platform-op",
    on_behalf_of_ref: "platform-op",
    access_record_ref: "stepup-1"
  }

  defp label, do: "tenant-key-" <> TenantFixture.random()

  defp data_key(scope) do
    keys = TenantFixture.keys!(scope)

    Keyring.data_key(%{
      tenant_id: scope.tenant_id,
      environment: scope.environment,
      subject_id: nil,
      key_id: keys.data
    })
  end

  defp kek_refs(scope) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          """
          SELECT tenant_id, environment, kek_ref FROM relay.tenant_keys
          WHERE state <> 'destroyed'
          """,
          []
        ).rows
      end)

    rows |> Enum.map(&List.last/1) |> Enum.uniq()
  end

  defp audit(scope, action) do
    {:ok, rows} =
      Repo.in_scope(scope, fn _status ->
        Repo.scoped_query!(
          """
          SELECT tenant_id, environment, reason, actor_ref FROM relay.audit_log
          WHERE action = $1
          """,
          [action]
        ).rows
      end)

    Enum.map(rows, &Enum.drop(&1, 2))
  end

  describe "OP-85 tenant key reference" do
    test "OP-85: a reference names the region's token and a key object of the tenant" do
      assert {:ok, %{token: "relay-tr", label: "acme"}} =
               KeyCustody.check("pkcs11:token=relay-tr;object=acme", "relay-tr")

      assert {:ok, %{token: "relay-tr"}} =
               KeyCustody.check("pkcs11:token=relay-tr;object=acme", nil)

      for ref <- [
            "pkcs11:object=acme",
            "pkcs11:token=relay-tr",
            "pkcs11:token=relay-tr;token=other;object=acme",
            "pkcs11:token=relay-tr;object=acme?pin-value=1234",
            "https://kms.example/acme",
            "pkcs11:token=relay-tr;object=kek-test"
          ] do
        assert {:error, %Relay.Error{code: :invalid_key_ref}} = KeyCustody.check(ref, "relay-tr")
      end

      assert {:error, %Relay.Error{code: :invalid_key_ref}} =
               KeyCustody.check("pkcs11:token=other-region;object=acme", "relay-tr")
    end

    test "OP-85: setting the key wraps every tenant key of both environments under it" do
      tenant = TenantFixture.tenant!()
      ref = "pkcs11:token=relay-test;object=" <> label()
      {:ok, before} = data_key(tenant.live)

      assert {:ok, %{key_ref: ^ref, result: :changed, rewrapped: rewrapped}} =
               Relay.TenantLifecycle.set_key_custody(tenant.id, ref, @actor)

      assert rewrapped == 4
      assert kek_refs(tenant.live) == [ref]
      assert kek_refs(tenant.test) == [ref]
      assert audit(tenant.live, "tenant.key_custody_changed") == [[ref, "platform-op"]]

      :ok = KeyCache.flush()
      assert {:ok, again} = data_key(tenant.live)
      assert Relay.Redacted.expose(again) == Relay.Redacted.expose(before)

      assert {:ok, %{key_ref: ^ref, keys: 4, other: 0}} =
               Relay.TenantLifecycle.key_custody(tenant.id)

      assert {:ok, %{result: :unchanged, rewrapped: 0}} =
               Relay.TenantLifecycle.set_key_custody(tenant.id, ref, @actor)
    end

    test "OP-85: a key the key store cannot use is refused and nothing changes" do
      tenant = TenantFixture.tenant!()
      gone = label()
      :ok = RelayTest.Keys.withdraw(gone)
      ref = "pkcs11:token=relay-test;object=" <> gone

      assert {:error, %Relay.Error{code: :key_unavailable}} =
               Relay.TenantLifecycle.set_key_custody(tenant.id, ref, @actor)

      assert {:ok, %{key_ref: nil, keys: 0, other: 4}} =
               Relay.TenantLifecycle.key_custody(tenant.id)

      assert audit(tenant.live, "tenant.key_custody_changed") == []
    end

    test "OP-85: reads fail closed and raise the alarm once the tenant's key is gone" do
      tenant = TenantFixture.tenant!()
      own = label()
      ref = "pkcs11:token=relay-test;object=" <> own
      {:ok, _set} = Relay.TenantLifecycle.set_key_custody(tenant.id, ref, @actor)

      handler = "custody-#{own}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:relay, :keys, :custody_unavailable],
        fn _event, measurements, meta, _config ->
          send(test_pid, {:alarm, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      :ok = RelayTest.Keys.withdraw(own)
      :ok = KeyCache.flush()

      assert {:error, %Relay.Error{code: :key_unavailable}} = data_key(tenant.live)
      tenant_text = Relay.Scope.tenant_text(tenant.live)
      assert_receive {:alarm, %{count: 1}, %{tenant_id: ^tenant_text}}
    end

    test "OP-85: keys provisioned after the key is set are wrapped under it" do
      tenant = TenantFixture.tenant!()
      ref = "pkcs11:token=relay-test;object=" <> label()
      {:ok, _set} = Relay.TenantLifecycle.set_key_custody(tenant.id, ref, @actor)

      assert {:ok, {label, ^ref}} = KeyCustody.wrapping(tenant.test, "kek-test")
      assert "pkcs11:token=relay-test;object=" <> ^label = ref

      other = TenantFixture.tenant!()
      assert {:ok, {"kek-test", "pkcs11:object=kek-test"}} =
               KeyCustody.wrapping(other.live, "kek-test")
    end

    test "OP-85: a closed tenant's key is not changed" do
      tenant = TenantFixture.tenant!()
      TenantFixture.retention_periods!()

      {:ok, _closure} =
        Relay.TenantLifecycle.request_closure(tenant.id, %{reason: "contract ended"}, @actor, nil)

      ref = "pkcs11:token=relay-test;object=" <> label()

      assert {:error, %Relay.Error{code: :tenant_closed}} =
               Relay.TenantLifecycle.set_key_custody(tenant.id, ref, @actor)
    end
  end

  describe "TN-34 HSM policy" do
    test "TN-34: a single-tenant HSM is a key store configuration change, same code path" do
      assert Relay.Keys.port_config_keys() == [:module, :token, :pin_file]

      cloud = [module: "/opt/cloud/lib/libpkcs11.so", token: "relay", pin_file: "/run/pin"]
      dedicated = [module: "/usr/lib/vendor/libpkcs11.so", token: "relay-tr", pin_file: "/run/a"]

      specs =
        for opts <- [cloud, dedicated] do
          previous = Application.get_env(:relay, Relay.Keys.Port)
          Application.put_env(:relay, Relay.Keys.Port, opts)

          try do
            assert [{Relay.Keys.Port, child}] = Relay.Keys.children()
            assert Relay.Keys.token() == opts[:token]
            child
          after
            if previous,
              do: Application.put_env(:relay, Relay.Keys.Port, previous),
              else: Application.delete_env(:relay, Relay.Keys.Port)
          end
        end

      assert specs == [cloud, dedicated]
      assert specs |> Enum.map(&Keyword.keys/1) |> Enum.uniq() == [[:module, :token, :pin_file]]

      sources = "lib/**/*.ex" |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)
      refute sources =~ ~r/cloudhsm|softhsm|luna|thales|yubihsm/i
    end
  end
end
