defmodule Relay.Platform.StreamSeqTest do
  use Relay.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Relay.Platform.OutboxStore
  alias Relay.Repo
  alias RelayTest.TenantFixture

  defp committed_tenant do
    Sandbox.unboxed_run(Repo, fn -> TenantFixture.tenant!() end)
  end

  defp take(scope, stream_key, fun \\ fn -> :ok end) do
    Sandbox.unboxed_run(Repo, fn ->
      OutboxStore.in_scope(scope, fn _ ->
        seq = OutboxStore.stream_next_seq(stream_key)
        fun.()
        seq
      end)
    end)
  end

  describe "C-71 OP-5 stream sequence follows commit order" do
    test "C-71: sequence numbers are consecutive per stream and independent across streams" do
      tenant = committed_tenant()
      stream = "inbox:" <> TenantFixture.random()

      assert {:ok, {epoch, 1}} = take(tenant.live, stream)
      assert {:ok, {^epoch, 2}} = take(tenant.live, stream)
      assert {:ok, {_, 1}} = take(tenant.live, "inbox:" <> TenantFixture.random())
      assert {:ok, {_, 1}} = take(tenant.test, stream)
    end

    test "C-71: a rolled back writer leaves no gap" do
      tenant = committed_tenant()
      stream = "inbox:" <> TenantFixture.random()

      {:ok, {_, 1}} = take(tenant.live, stream)

      assert {:error, :rolled_back} =
               Sandbox.unboxed_run(Repo, fn ->
                 OutboxStore.in_scope(tenant.live, fn _ ->
                   {_, 2} = OutboxStore.stream_next_seq(stream)
                   Repo.rollback(:rolled_back)
                 end)
               end)

      assert {:ok, {_, 2}} = take(tenant.live, stream)
    end

    test "C-71: a concurrent writer waits, so sequence order is commit order" do
      tenant = committed_tenant()
      stream = "inbox:" <> TenantFixture.random()
      parent = self()

      first =
        Task.async(fn ->
          take(tenant.live, stream, fn ->
            send(parent, :first_holds)

            receive do
              :commit -> :ok
            end
          end)
        end)

      assert_receive :first_holds, 5_000

      second = Task.async(fn -> take(tenant.live, stream) end)
      refute Task.yield(second, 300)

      send(first.pid, :commit)
      assert {:ok, {_, 1}} = Task.await(first)
      assert {:ok, {_, 2}} = Task.await(second)
    end
  end
end
