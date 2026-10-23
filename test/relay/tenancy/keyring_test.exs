defmodule Relay.Tenancy.KeyringTest do
  use Relay.DataCase, async: false

  import Mox

  alias Relay.Keys.Erasure
  alias Relay.Redacted
  alias Relay.Tenancy.KeyCache
  alias Relay.Tenancy.Provisioning
  alias RelayTest.TenantFixture, as: Fixture

  setup :verify_on_exit!

  @kek :binary.copy(<<0x4B>>, 32)
  @bidx :binary.copy(<<0x0B>>, 32)

  setup do
    previous = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)
    on_exit(fn -> Application.put_env(:relay, :keys, previous) end)

    unwraps = :counters.new(1, [])
    generated = :ets.new(:generated, [:public, :bag])
    stub(Relay.KeysMock, :wrap, &hsm_wrap/3)

    stub(Relay.KeysMock, :unwrap, fn label, aad, wrapped ->
      :counters.add(unwraps, 1, 1)
      hsm_unwrap(label, aad, wrapped)
    end)

    stub(Relay.KeysMock, :generate_key, fn kind, label, id ->
      :ets.insert(generated, {kind, label, id})
      :ok
    end)

    stub(Relay.KeysMock, :hmac_sha256, fn "relay-bidx/" <> _, %Redacted{} = message ->
      {:ok, :crypto.mac(:hmac, :sha256, @bidx, Redacted.expose(message))}
    end)

    :ok = Relay.Tenancy.flush_key_cache()
    tenant = Fixture.tenant!()
    scope = tenant.live
    keys = Fixture.keys!(scope)

    %{
      scope: scope,
      tenant: tenant.id,
      data: keys.data,
      wrap: keys.dek_wrap,
      bidx: keys.blind_index,
      unwraps: unwraps,
      generated: generated
    }
  end

  defp hsm_wrap("kek-test", aad, key) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, @kek, iv, Redacted.expose(key), aad, 16, true)

    {:ok, iv <> ciphertext <> tag}
  end

  defp hsm_unwrap("kek-test", aad, <<iv::binary-12, rest::binary>>) do
    size = byte_size(rest) - 16
    <<ciphertext::binary-size(^size), tag::binary-16>> = rest

    case :crypto.crypto_one_time_aead(:aes_256_gcm, @kek, iv, ciphertext, aad, tag, false) do
      :error -> {:error, Relay.Error.new(:key_integrity, "key store: authentication failed")}
      key -> {:ok, Redacted.wrap(key)}
    end
  end

  defp field(ctx, subject),
    do: %{
      tenant_id: ctx.tenant,
      environment: :live,
      subject_id: subject,
      retention_class: :recipient_profile,
      table: "recipients",
      column: "external_id_ct"
    }

  defp index(ctx), do: %{tenant_id: ctx.tenant, environment: :live, purpose: "external_id"}

  defp recipient!(ctx, value) do
    id = Relay.Id.generate()

    {:ok, {:created, ^id}} =
      Relay.Tenancy.create_recipient(ctx.scope, %{id: id, kind: :subscriber, external_id: value})

    [[stored]] =
      scoped!(ctx.scope, "SELECT external_id_ct FROM relay.recipients WHERE id = $1", [id])

    {id, stored}
  end

  defp scoped!(scope, sql, params) do
    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _ -> Relay.Repo.scoped_query!(sql, params).rows end)

    rows
  end

  defp decrypt(ctx, id, stored), do: Relay.Tenancy.decrypt_field(field(ctx, id), stored)

  defp load_retention_periods!, do: Fixture.retention_periods!()

  describe "TN-67 key provisioning" do
    test "TN-67 (1): creating a tenant provisions both environments' data, wrapping and blind index keys",
         ctx do
      for environment <- [:live, :test] do
        scope = Relay.Scope.new!(ctx.tenant, environment)

        rows =
          scoped!(
            scope,
            "SELECT purpose, kek_ref, state FROM relay.tenant_keys ORDER BY purpose",
            []
          )

        assert rows == [
                 ["data", "pkcs11:object=kek-test", "active"],
                 ["dek_wrap", "pkcs11:object=kek-test", "active"]
               ]

        [[id, hsm_ref, "active"]] =
          scoped!(scope, "SELECT id, hsm_ref, state FROM relay.blind_index_keys", [])

        label = Provisioning.blind_index_label(scope, id)
        assert {:ok, ^label} = Relay.Keys.label(hsm_ref)
        assert {:hmac_sha256, label, id} in :ets.lookup(ctx.generated, :hmac_sha256)
      end

      assert :ets.info(ctx.generated, :size) == 2
    end

    test "TN-67 (1): a repeated mapping event provisions nothing new", ctx do
      {:ok, tenant} = Relay.Tenancy.tenant(ctx.scope)

      attrs = %{
        id: ctx.tenant,
        access_tenant_id: tenant["access_tenant_id"],
        region: Fixture.region(),
        sector: tenant["sector"],
        default_timezone: tenant["default_timezone"],
        default_locale: tenant["default_locale"],
        record_digest: Fixture.digest()
      }

      assert Provisioning.create_tenant(attrs, Fixture.actor()) ==
               {:exists, ctx.tenant}

      assert :ets.info(ctx.generated, :size) == 2

      assert [[2]] = scoped!(ctx.scope, "SELECT count(*) FROM relay.tenant_keys", [])
    end

    test "TN-67 (1): a recipient is created with its profile data key under the tenant's wrapping key",
         ctx do
      {id, stored} = recipient!(ctx, "ada@example.com")

      [[class, wrapping_key_id, state]] =
        scoped!(
          ctx.scope,
          "SELECT retention_class::text, wrapping_key_id, state FROM relay.subject_keys WHERE recipient_id = $1",
          [id]
        )

      assert {class, wrapping_key_id, state} == {"recipient_profile", ctx.wrap, "active"}
      assert Redacted.expose(elem(decrypt(ctx, id, stored), 1)) == "ada@example.com"

      [[bidx, bidx_key]] =
        scoped!(
          ctx.scope,
          "SELECT external_id_bidx, external_id_bidx_key_id FROM relay.recipients WHERE id = $1",
          [id]
        )

      assert {:ok, {^bidx_key, ^bidx}} = Relay.Tenancy.blind_index(index(ctx), "ada@example.com")
    end
  end

  describe "TN-27 envelope encryption" do
    test "TN-27: a tenant key is generated, wrapped under the KEK inside the key store, registered and unwrapped",
         ctx do
      [[kek_ref, wrapped, state]] =
        scoped!(
          ctx.scope,
          "SELECT kek_ref, wrapped_key, state FROM relay.tenant_keys WHERE id = $1",
          [ctx.data]
        )

      assert kek_ref == "pkcs11:object=kek-test"
      assert state == "active"
      assert <<1, _iv::binary-12, _key::binary-32, _tag::binary-16>> = wrapped

      tenant_field = %{field(ctx, nil) | table: "audit_log", column: "details_ct"}
      tenant_field = Map.put(%{tenant_field | retention_class: :audit}, :key_id, ctx.data)

      assert {:ok, stored} = Relay.Tenancy.encrypt_field(tenant_field, "operator note")
      assert {:ok, plain} = Relay.Tenancy.decrypt_field(tenant_field, stored)
      assert Redacted.expose(plain) == "operator note"

      wrong_purpose = Map.put(tenant_field, :key_id, ctx.wrap)

      assert {:error, %Relay.Error{code: :invalid_key_purpose}} =
               Relay.Tenancy.decrypt_field(wrong_purpose, stored)
    end

    test "TN-33: a subject data key is wrapped under the tenant key and decrypts its fields",
         ctx do
      {id, stored} = recipient!(ctx, "ada@example.com")
      assert {:ok, plain} = decrypt(ctx, id, stored)
      assert Redacted.expose(plain) == "ada@example.com"

      [[wrapped_dek]] =
        scoped!(
          ctx.scope,
          "SELECT wrapped_dek FROM relay.subject_keys WHERE recipient_id = $1",
          [id]
        )

      assert <<1, _iv::binary-12, _dek::binary-32, _tag::binary-16>> = wrapped_dek
    end

    test "TN-66: the tenant key is unwrapped once per cache lifetime, not per field", ctx do
      {id, stored} = recipient!(ctx, "ada@example.com")
      :ok = Relay.Tenancy.flush_key_cache()
      before = :counters.get(ctx.unwraps, 1)

      for _ <- 1..5, do: assert({:ok, _} = decrypt(ctx, id, stored))
      assert :counters.get(ctx.unwraps, 1) == before + 1

      :ok = Relay.Tenancy.flush_key_cache()
      assert {:ok, _} = decrypt(ctx, id, stored)
      assert :counters.get(ctx.unwraps, 1) == before + 2
    end

    test "OP-18: a data key restricted under a statutory retention is refused, even after it was cached",
         ctx do
      load_retention_periods!()
      {id, _stored} = recipient!(ctx, "ada@example.com")

      {:ok, %{wrapped_dek: wrapped, data_key: dek}} =
        Relay.Tenancy.generate_subject_key(ctx.scope, ctx.wrap, id, :delivery_record)

      [["created", _key_id]] =
        scoped!(
          ctx.scope,
          "SELECT result, subject_key_id FROM relay_fn.subject_key_create($1, $2, $3, $4, $5)",
          [Relay.Id.generate(), id, "delivery_record", wrapped, ctx.wrap]
        )

      record = %{
        field(ctx, id)
        | retention_class: :delivery_record,
          table: "deliveries",
          column: "target_ct"
      }

      {:ok, stored} = Relay.Tenancy.encrypt_field(record, "+905551112233", data_key: dek)
      assert {:ok, _} = Relay.Tenancy.decrypt_field(record, stored)

      assert {:ok, :erased, 0} =
               Erasure.erase_subject(ctx.scope, id, "dsr-restrict", Fixture.actor())

      assert {:error, %Relay.Error{code: :data_key_restricted}} =
               Relay.Tenancy.decrypt_field(record, stored)
    end

    test "OP-17: a destroyed data key no longer decrypts", ctx do
      load_retention_periods!()
      {id, stored} = recipient!(ctx, "ada@example.com")
      assert {:ok, _} = decrypt(ctx, id, stored)

      assert {:ok, :erased, 0} =
               Erasure.erase_subject(ctx.scope, id, "dsr-destroy", Fixture.actor())

      assert {:error, %Relay.Error{code: :data_key_destroyed}} = decrypt(ctx, id, stored)
    end

    test "TN-66: a key destruction signal empties this node's key cache", ctx do
      {id, stored} = recipient!(ctx, "ada@example.com")
      assert {:ok, _} = decrypt(ctx, id, stored)
      assert KeyCache.size() > 0

      eviction = Process.whereis(Relay.Keys.Eviction)
      send(eviction, {:relay_signal, Relay.Keys.Eviction.topic(), {:seq, 1}})
      _ = :sys.get_state(eviction)

      assert KeyCache.size() == 0
    end

    test "TN-66: the blind index is computed inside the key store under the tenant's key", ctx do
      message =
        Relay.Canonical.encode!([
          {:bytes, ctx.tenant},
          "live",
          "external_id",
          {:bytes, "ada@example.com"}
        ])

      assert Relay.Tenancy.blind_index(index(ctx), "ada@example.com") ==
               {:ok, {ctx.bidx, :crypto.mac(:hmac, :sha256, @bidx, message)}}
    end
  end
end
