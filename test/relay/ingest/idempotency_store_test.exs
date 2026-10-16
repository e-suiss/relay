defmodule Relay.Ingest.IdempotencyStoreTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Ingest.Store
  alias Relay.Repo
  alias RelayTest.TenantFixture

  @endpoint "POST /v1/events"

  setup do
    TenantFixture.as_role("relay_worker")
    tenant = TenantFixture.tenant!()

    %{
      tenant: tenant,
      keys: TenantFixture.keys!(tenant.live),
      test_keys: TenantFixture.keys!(tenant.test)
    }
  end

  defp response(key_id, status \\ 202),
    do: %{
      status: status,
      headers: %{"content-type" => "application/json"},
      body_ct: "sealed-" <> TenantFixture.random(),
      body_key_id: key_id
    }

  defp claim_and_store(scope, endpoint, key, fingerprint, response) do
    {:ok, stored} =
      Store.in_scope(scope, fn _ ->
        {:created, nil} = Store.idempotency_begin(endpoint, key, fingerprint)
        Store.idempotency_complete(endpoint, key, fingerprint, response)
      end)

    stored
  end

  defp begin(scope, endpoint, key, fingerprint) do
    {:ok, result} =
      Store.in_scope(scope, fn _ -> Store.idempotency_begin(endpoint, key, fingerprint) end)

    result
  end

  describe "API-11 OP-6 C-79 idempotency in PostgreSQL" do
    test "OP-6: a replay returns the stored response exactly", %{tenant: t, keys: keys} do
      key = "key-" <> TenantFixture.random()
      fp = TenantFixture.digest()
      stored = response(keys.data)

      assert claim_and_store(t.live, @endpoint, key, fp, stored) == :stored
      assert {:replayed, replay} = begin(t.live, @endpoint, key, fp)
      assert replay == stored
    end

    test "C-79: the same key with a different body is a conflict", %{tenant: t, keys: keys} do
      key = "key-" <> TenantFixture.random()

      :stored =
        claim_and_store(t.live, @endpoint, key, TenantFixture.digest(), response(keys.data))

      assert {:conflict, nil} = begin(t.live, @endpoint, key, TenantFixture.digest())
    end

    test "API-11: the scope is tenant, environment, endpoint and key", %{
      tenant: t,
      keys: keys
    } do
      key = "key-" <> TenantFixture.random()
      fp = TenantFixture.digest()
      :stored = claim_and_store(t.live, @endpoint, key, fp, response(keys.data))

      assert {:created, nil} = begin(t.test, @endpoint, key, fp)
      assert {:created, nil} = begin(t.live, "POST /v1/subscribers", key, fp)

      other = TenantFixture.tenant!()
      TenantFixture.keys!(other.live)
      assert {:created, nil} = begin(other.live, @endpoint, key, fp)
    end

    test "API-11: keys of 7 and 256 characters are refused by the database", %{
      tenant: t,
      keys: keys
    } do
      for key <- ["k234567", String.duplicate("k", 256)] do
        assert_raise Postgrex.Error, fn ->
          claim_and_store(t.live, @endpoint, key, TenantFixture.digest(), response(keys.data))
        end
      end
    end

    test "API-14: a 429 is not stored and the key stays free", %{tenant: t, keys: keys} do
      key = "key-" <> TenantFixture.random()
      fp = TenantFixture.digest()

      assert claim_and_store(t.live, @endpoint, key, fp, response(keys.data, 429)) ==
               :not_cacheable

      assert {:created, nil} = begin(t.live, @endpoint, key, fp)
    end

    test "API-14: a response is stored only for a key claimed in the same transaction", %{
      tenant: t,
      keys: keys
    } do
      assert {:ok, :not_claimed} =
               Store.in_scope(t.live, fn _ ->
                 Store.idempotency_complete(
                   @endpoint,
                   "key-" <> TenantFixture.random(),
                   TenantFixture.digest(),
                   response(keys.data)
                 )
               end)
    end

    test "API-14: a rolled back transaction leaves no stored response", %{tenant: t, keys: keys} do
      key = "key-" <> TenantFixture.random()
      fp = TenantFixture.digest()

      assert {:error, :failed} =
               Store.in_scope(t.live, fn _ ->
                 {:created, nil} = Store.idempotency_begin(@endpoint, key, fp)
                 :stored = Store.idempotency_complete(@endpoint, key, fp, response(keys.data))
                 Repo.rollback(:failed)
               end)

      assert {:created, nil} = begin(t.live, @endpoint, key, fp)
    end
  end

  describe "OP-6 provider receipts" do
    test "OP-6: a repeated provider event is a duplicate receipt, per environment", %{tenant: t} do
      receipt = fn ->
        %{
          id: Relay.Id.generate(),
          provider: "mailpit",
          provider_event_id: "evt-1",
          body_digest: :crypto.hash(:sha256, "body")
        }
      end

      assert {:ok, {:recorded, id}} = Relay.Webhooks.record_receipt(t.live, receipt.())
      assert {:ok, {:duplicate, _}} = Relay.Webhooks.record_receipt(t.live, receipt.())
      assert {:ok, {:recorded, _}} = Relay.Webhooks.record_receipt(t.test, receipt.())

      assert {:ok, :marked} = Relay.Webhooks.mark_receipt(t.live, id, :rejected, "unknown event")
      assert {:ok, :already_final} = Relay.Webhooks.mark_receipt(t.live, id, :processed, nil)
    end
  end

  describe "API-15 first claim wins" do
    test "API-15: two concurrent claims of one key give one created and one in progress" do
      tenant =
        Sandbox.unboxed_run(Repo, fn ->
          tenant = TenantFixture.tenant!()
          TenantFixture.keys!(tenant.live)
          tenant
        end)

      key = "key-" <> TenantFixture.random()
      fp = TenantFixture.digest()
      parent = self()

      first =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Store.in_scope(tenant.live, fn _ ->
              send(parent, {:first, Store.idempotency_begin(@endpoint, key, fp)})

              receive do
                :release -> Repo.rollback(:released)
              end
            end)
          end)
        end)

      assert_receive {:first, {:created, nil}}, 5_000

      second =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Store.in_scope(tenant.live, fn _ -> Store.idempotency_begin(@endpoint, key, fp) end)
          end)
        end)

      assert Task.await(second) == {:ok, {:in_progress, nil}}
      send(first.pid, :release)
      assert Task.await(first) == {:error, :released}
    end
  end
end
