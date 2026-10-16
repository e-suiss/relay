defmodule Relay.Tenancy.BlindIndexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Relay.Redacted
  alias Relay.Tenancy.KeyProviderMock

  setup :verify_on_exit!

  @tenant <<1::128>>
  @key_v1 :binary.copy(<<1>>, 32)
  @key_v2 :binary.copy(<<2>>, 32)
  @scope %{tenant_id: @tenant, environment: :live, purpose: "email"}
  @opts [key_provider: KeyProviderMock]

  defp keys(list),
    do: fn _scope -> {:ok, Enum.map(list, fn {v, k} -> {v, Redacted.wrap(k)} end)} end

  defp expected(key, scope, value) do
    message =
      Relay.Canonical.encode!([
        {:bytes, scope.tenant_id},
        Atom.to_string(scope.environment),
        scope.purpose,
        {:bytes, value}
      ])

    :crypto.mac(:hmac, :sha256, key, message)
  end

  describe "TN-33 blind index" do
    test "TN-33: the index is HMAC-SHA256 over the canonical scope and value under the current key" do
      stub(KeyProviderMock, :blind_index_keys, keys([{2, @key_v2}, {1, @key_v1}]))

      assert Relay.Tenancy.blind_index(@scope, "a@example.com", @opts) ==
               {:ok, {2, expected(@key_v2, @scope, "a@example.com")}}
    end

    test "TN-33: the key provider receives the index scope" do
      expect(KeyProviderMock, :blind_index_keys, fn scope ->
        assert scope == @scope
        {:ok, [{1, Redacted.wrap(@key_v1)}]}
      end)

      assert {:ok, {1, _}} =
               Relay.Tenancy.blind_index(@scope, Redacted.wrap("a@example.com"), @opts)
    end

    property "TN-33: the index separates tenants, environments and purposes" do
      stub(KeyProviderMock, :blind_index_keys, keys([{1, @key_v1}]))

      check all value <- binary(min_length: 1),
                other_tenant <- binary(length: 16),
                other_tenant != @tenant do
        {:ok, {1, base}} = Relay.Tenancy.blind_index(@scope, value, @opts)

        for scope <- [
              %{@scope | tenant_id: other_tenant},
              %{@scope | environment: :test},
              %{@scope | purpose: "phone"}
            ] do
          {:ok, {1, other}} = Relay.Tenancy.blind_index(scope, value, @opts)
          refute other == base
        end
      end
    end

    property "TN-33: the index is deterministic and contains no plain text" do
      stub(KeyProviderMock, :blind_index_keys, keys([{1, @key_v1}]))

      check all value <- string(:alphanumeric, min_length: 4) do
        {:ok, {1, a}} = Relay.Tenancy.blind_index(@scope, value, @opts)
        {:ok, {1, b}} = Relay.Tenancy.blind_index(@scope, value, @opts)

        assert a == b
        assert byte_size(a) == 32
        refute :binary.match(a, value) != :nomatch
      end
    end

    test "TN-33: during rotation every readable key yields an index, the current key first" do
      stub(KeyProviderMock, :blind_index_keys, keys([{2, @key_v2}, {1, @key_v1}]))

      assert {:ok, [{2, new}, {1, old}]} =
               Relay.Tenancy.blind_index_digests(@scope, "a@example.com", @opts)

      assert new == expected(@key_v2, @scope, "a@example.com")
      assert old == expected(@key_v1, @scope, "a@example.com")
    end

    test "TN-33: a row indexed under the previous key is still found after the current key changes" do
      stub(KeyProviderMock, :blind_index_keys, keys([{1, @key_v1}]))
      {:ok, stored} = Relay.Tenancy.blind_index(@scope, "a@example.com", @opts)

      stub(KeyProviderMock, :blind_index_keys, keys([{2, @key_v2}, {1, @key_v1}]))
      {:ok, computed} = Relay.Tenancy.blind_index_digests(@scope, "a@example.com", @opts)
      {:ok, other} = Relay.Tenancy.blind_index_digests(@scope, "b@example.com", @opts)

      assert Relay.Tenancy.blind_index_match?(computed, stored)
      refute Relay.Tenancy.blind_index_match?(other, stored)
      refute Relay.Tenancy.blind_index_match?(computed, {3, elem(stored, 1)})
    end

    test "TN-33: key provider errors are returned and a provider without keys is an error" do
      error = Relay.Error.new(:key_store_unavailable, "down")
      expect(KeyProviderMock, :blind_index_keys, fn _ -> {:error, error} end)
      assert Relay.Tenancy.blind_index(@scope, "a", @opts) == {:error, error}

      expect(KeyProviderMock, :blind_index_keys, fn _ -> {:ok, []} end)

      assert {:error, %Relay.Error{code: :blind_index_key_unavailable}} =
               Relay.Tenancy.blind_index(@scope, "a", @opts)
    end

    test "TN-33: an invalid scope is refused before any key is requested" do
      for scope <- [
            %{@scope | tenant_id: "short"},
            %{@scope | environment: :staging},
            %{@scope | purpose: ""},
            %{tenant_id: @tenant}
          ] do
        assert {:error, %Relay.Error{code: :invalid_scope}} =
                 Relay.Tenancy.blind_index(scope, "a", @opts)
      end
    end
  end
end
