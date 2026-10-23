defmodule Relay.SecretsDatabaseTest do
  use Relay.DataCase, async: false

  alias Relay.Redacted
  alias Relay.Secrets
  alias RelayTest.TenantFixture, as: Fixture

  @v1 "SECRETS_DB_TEST_TOKEN"
  @v2 "SECRETS_DB_TEST_TOKEN_NEXT"

  setup do
    System.put_env(@v1, "token-one-#{System.unique_integer([:positive])}")
    System.put_env(@v2, "token-two-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      System.delete_env(@v1)
      System.delete_env(@v2)
    end)

    tenant = Fixture.tenant!()
    id = Relay.Id.generate()

    attrs = %{
      id: id,
      kind: :webhook_signing,
      ref: "${#{@v1}}",
      ref_version: 1,
      record_digest: Fixture.digest()
    }

    assert {:ok, :created} = Secrets.register(tenant.live, attrs, Fixture.actor())
    %{scope: tenant.live, id: id, attrs: attrs}
  end

  defp fingerprint(secret),
    do: :crypto.mac(:hmac, :sha256, RelayTest.Keys.secret("fingerprint-test"), secret)

  defp stored(scope, id) do
    {:ok, row} =
      Relay.Repo.in_scope(scope, fn _ ->
        Relay.Repo.scoped_query!(
          "SELECT ref, secret_ct, fingerprint, row_to_json(s)::text FROM relay.secret_refs s WHERE id = $1",
          [id]
        ).rows
      end)

    row
  end

  defp await_up(topic, tries \\ 100) do
    case Relay.Platform.Signal.Hub.topics(Relay.Platform.Signal.Hub) do
      %{^topic => :up} ->
        :ok

      _ when tries > 0 ->
        receive do
        after
          50 -> await_up(topic, tries - 1)
        end
    end
  end

  describe "TN-26 INV-51 stored secret references" do
    test "TN-26: the database keeps the reference and the fingerprint, never the secret", ctx do
      secret = System.get_env(@v1)
      [[ref, secret_ct, fingerprint, json]] = stored(ctx.scope, ctx.id)

      assert ref == "${#{@v1}}"
      assert secret_ct == nil
      assert fingerprint == fingerprint(secret)
      refute fingerprint == :crypto.hash(:sha256, secret)
      refute json =~ secret
    end

    test "INV-51: a stored reference reads back as its fingerprint only", ctx do
      assert {:ok, %Secrets.Ref{} = ref} = Secrets.get(ctx.scope, ctx.id)
      assert ref.fingerprint == fingerprint(System.get_env(@v1))
      assert ref.state == :active
      refute Map.has_key?(Map.from_struct(ref), :ref)
      refute inspect(ref, limit: :infinity) =~ System.get_env(@v1)
      refute inspect(ref) =~ @v1
    end

    test "INV-51: the secret is resolved only by the caller and refused once it changed behind its reference",
         ctx do
      assert {:ok, secret} = Secrets.fetch(ctx.scope, ctx.id)
      assert Redacted.expose(secret) == System.get_env(@v1)

      System.put_env(@v1, "changed-out-of-band")

      assert {:error, %Relay.Error{code: :secret_changed}} = Secrets.fetch(ctx.scope, ctx.id)
    end

    test "TN-26: a reference that does not resolve is not registered", ctx do
      attrs = %{ctx.attrs | id: Relay.Id.generate(), ref: "${SECRETS_DB_TEST_UNSET}"}

      assert {:error, %Relay.Error{code: :secret_unavailable}} =
               Secrets.register(ctx.scope, attrs, Fixture.actor())
    end

    test "TN-26: rotation registers the new reference, retires the old one and tells the holders without a restart",
         ctx do
      {:ok, topic} = Secrets.topic(ctx.scope)
      :ok = Secrets.subscribe_rotations(ctx.scope)
      :ok = await_up(topic)

      new = %{ctx.attrs | id: Relay.Id.generate(), ref: "${#{@v2}}", ref_version: 2}

      assert {:ok, :rotated} =
               Secrets.rotate(ctx.scope, ctx.id, new, Fixture.digest(), Fixture.actor())

      assert_receive {:relay_signal, ^topic, {:seq, 2}}, 5_000

      assert {:ok, %Secrets.Ref{state: :retired}} = Secrets.get(ctx.scope, ctx.id)

      assert {:error, %Relay.Error{code: :secret_retired}} = Secrets.fetch(ctx.scope, ctx.id)
      assert {:ok, secret} = Secrets.fetch(ctx.scope, new.id)
      assert Redacted.expose(secret) == System.get_env(@v2)

      assert {:error, %Relay.Error{code: :rotation_refused}} =
               Secrets.rotate(
                 ctx.scope,
                 ctx.id,
                 %{new | id: Relay.Id.generate(), ref_version: 3},
                 Fixture.digest(),
                 Fixture.actor()
               )
    end
  end
end
