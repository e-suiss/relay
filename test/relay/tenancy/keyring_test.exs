defmodule Relay.Tenancy.KeyringTest do
  use Relay.DataCase, async: false

  import Mox

  alias Relay.Keys.Erasure
  alias Relay.Redacted
  alias Relay.Tenancy.KeyCache
  alias RelayTest.TenantFixture, as: Fixture

  setup :verify_on_exit!

  @kek :binary.copy(<<0x4B>>, 32)
  @bidx :binary.copy(<<0x0B>>, 32)

  setup do
    previous = Application.fetch_env!(:relay, :keys)
    Application.put_env(:relay, :keys, Relay.KeysMock)
    on_exit(fn -> Application.put_env(:relay, :keys, previous) end)

    unwraps = :counters.new(1, [])
    stub(Relay.KeysMock, :wrap, &hsm_wrap/3)

    stub(Relay.KeysMock, :unwrap, fn label, aad, wrapped ->
      :counters.add(unwraps, 1, 1)
      hsm_unwrap(label, aad, wrapped)
    end)

    stub(Relay.KeysMock, :hmac_sha256, fn "bidx-test", %Redacted{} = message ->
      {:ok, :crypto.mac(:hmac, :sha256, @bidx, Redacted.expose(message))}
    end)

    :ok = Relay.Tenancy.flush_key_cache()
    tenant = Fixture.tenant!()
    scope = tenant.live
    data = Relay.Id.generate()
    wrap = Relay.Id.generate()
    bidx = Relay.Id.generate()

    for {id, purpose} <- [{data, :data}, {wrap, :dek_wrap}] do
      assert {:ok, :created} =
               Relay.Tenancy.provision_tenant_key(
                 scope,
                 %{
                   id: id,
                   purpose: purpose,
                   kek_label: "kek-test",
                   record_digest: Fixture.digest()
                 },
                 Fixture.actor()
               )
    end

    {:ok, :created} =
      Relay.Tenancy.register_blind_index_key(
        scope,
        %{id: bidx, hsm_ref: Relay.Keys.uri("bidx-test"), record_digest: Fixture.digest()},
        Fixture.actor()
      )

    %{scope: scope, tenant: tenant.id, data: data, wrap: wrap, bidx: bidx, unwraps: unwraps}
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

    {:ok, %{wrapped_dek: wrapped, data_key: dek}} =
      Relay.Tenancy.generate_subject_key(ctx.scope, ctx.wrap, id, :recipient_profile)

    {:ok, stored} = Relay.Tenancy.encrypt_field(field(ctx, id), value, data_key: dek)
    {:ok, {bidx_key, bidx}} = Relay.Tenancy.blind_index(index(ctx), value)

    {:ok, {:created, ^id}} =
      Relay.Tenancy.create_recipient(ctx.scope, %{
        id: id,
        kind: :subscriber,
        external_id_bidx: bidx,
        bidx_key_id: bidx_key,
        external_id_ct: stored,
        profile_dek_id: Relay.Id.generate(),
        profile_wrapped_dek: wrapped,
        wrapping_key_id: ctx.wrap
      })

    {id, stored}
  end

  defp scoped!(scope, sql, params) do
    {:ok, rows} =
      Relay.Repo.in_scope(scope, fn _ -> Relay.Repo.scoped_query!(sql, params).rows end)

    rows
  end

  defp decrypt(ctx, id, stored), do: Relay.Tenancy.decrypt_field(field(ctx, id), stored)

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
      {id, stored} = recipient!(ctx, "ada@example.com")
      assert {:ok, _} = decrypt(ctx, id, stored)

      assert {:ok, :erased, 0} =
               Erasure.erase_subject(
                 ctx.scope,
                 id,
                 "dsr-restrict",
                 ["recipient_profile"],
                 Fixture.actor()
               )

      assert {:error, %Relay.Error{code: :data_key_restricted}} = decrypt(ctx, id, stored)
    end

    test "OP-17: a destroyed data key no longer decrypts", ctx do
      {id, stored} = recipient!(ctx, "ada@example.com")
      assert {:ok, _} = decrypt(ctx, id, stored)

      assert {:ok, :erased, 0} =
               Erasure.erase_subject(ctx.scope, id, "dsr-destroy", [], Fixture.actor())

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
