defmodule Relay.Policy.FrequencyCounterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Relay.Platform.Backend
  alias Relay.Platform.Valkey
  alias Relay.Policy.Fixture
  alias Relay.Policy.FrequencyCounter
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  @global %{kind: :global, limit: 12, window_ms: 86_400_000, category: nil, channel: nil}
  @policy %{kind: :policy, limit: 2, window_ms: 60_000, category: "orders", channel: :push}

  defp mocked, do: [backend: __MODULE__.Unstarted, adapter: ValkeyMock]

  defp scope, do: Relay.Scope.new!(Fixture.tenant_id(), :live)

  defp read(keys, opts \\ mocked()) do
    recipient = Fixture.recipient_id()
    FrequencyCounter.read(scope(), recipient, Fixture.delivery_id(), keys, opts)
  end

  defp record(keys) do
    recipient = Fixture.recipient_id()
    FrequencyCounter.record(scope(), recipient, Fixture.delivery_id(), keys, mocked())
  end

  defp attach do
    ref = make_ref()
    pid = self()
    handler = "frequency-counter-test-#{inspect(ref)}"
    event = [:relay, :frequency_counter, :unavailable]

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, meta, _config -> send(pid, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  defp wait_pg(_name, 0), do: flunk("the backend did not move to pg")

  defp wait_pg(name, n) do
    if Backend.state(name).phase == :pg,
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_pg(name, n - 1)
        )
  end

  describe "PC-50 PC-58 (6) unit" do
    test "PC-58 (6): a read leaves the delivery out and names its tenant-prefixed key" do
      tenant = Relay.Id.to_string(Fixture.tenant_id())
      recipient = Relay.Id.to_string(Fixture.recipient_id())
      delivery = Relay.Id.to_string(Fixture.delivery_id())
      key = "relay:t:#{tenant}:live:fq:g:#{recipient}"

      expect(ValkeyMock, :command, fn command ->
        assert ["EVALSHA", _sha, "1", ^key, "count", "86400000", ^delivery, "12"] = command
        {:ok, [12, 1_790_000_360_000, 1_790_000_000_000]}
      end)

      assert %{global: %{count: 12, free_at: free_at}, policy: nil} = read([@global])
      assert free_at == DateTime.from_unix!(1_790_000_360_000, :millisecond)
    end

    test "PC-58 (6): the policy key carries a digest of the category and the channel" do
      expect(ValkeyMock, :command, fn ["EVALSHA", _sha, "1", key, "count", "60000", _, "2"] ->
        assert [_, _, _, _, "fq", "p", _recipient, digest, "push"] = String.split(key, ":")
        assert digest =~ ~r/\A[0-9a-f]{32}\z/
        {:ok, [1, 0, 1_790_000_000_000]}
      end)

      assert %{global: nil, policy: %{count: 1, free_at: nil}} = read([@policy])
    end

    test "PC-58 (6): a send is recorded in every counter" do
      expect(ValkeyMock, :command, 2, fn ["EVALSHA", _sha, "1", _key, "add", _, _, "1"] ->
        {:ok, [1, 0, 1_790_000_000_000]}
      end)

      assert :ok = record([@global, @policy])
    end

    test "PC-50 INV-45: an unanswered read or record is :unavailable, with telemetry and a log" do
      ref = attach()

      expect(ValkeyMock, :command, 2, fn ["EVALSHA" | _] ->
        {:error, %Redix.ConnectionError{reason: :closed}}
      end)

      log =
        capture_log(fn ->
          assert :unavailable = read([@global, @policy])
          assert :unavailable = record([@global])
        end)

      assert log =~ "frequency counter unavailable"
      assert_receive {^ref, %{count: 1}, %{op: :read}}
      assert_receive {^ref, %{count: 1}, %{op: :record}}
    end

    test "PC-50: while the node's limit backend is on PostgreSQL the counter is not asked" do
      name = __MODULE__.Backend
      options = [name: name, adapter: ValkeyMock, hold_ms: 60_000, ping_ms: 60_000]
      start_supervised!({Backend, options})

      capture_log(fn ->
        Backend.report_failure(name)
        wait_pg(name, 100)
        assert :unavailable = read([@global], backend: name, adapter: ValkeyMock)
      end)
    end
  end

  describe "PC-50 PC-58 (6) on Valkey" do
    @describetag :integration

    setup do
      await_valkey(100)
      %{scope: Relay.Scope.new!(Relay.Id.generate(), :test), recipient: Relay.Id.generate()}
    end

    test "PC-58 (6): recording is idempotent per delivery and a read leaves the reader out", %{
      scope: scope,
      recipient: recipient
    } do
      [a, b, c] = for _ <- 1..3, do: Relay.Id.generate()
      read = &FrequencyCounter.read(scope, recipient, &1, &2, real())

      assert :ok = FrequencyCounter.record(scope, recipient, a, [@global, @policy], real())
      assert :ok = FrequencyCounter.record(scope, recipient, a, [@global, @policy], real())

      assert %{global: %{count: 1, free_at: nil}, policy: %{count: 1, free_at: nil}} =
               read.(c, [@global, @policy])

      assert %{global: %{count: 0}} = read.(a, [@global])
      assert :ok = FrequencyCounter.record(scope, recipient, b, [@policy], real())
      assert %{policy: %{count: 2, free_at: %DateTime{} = free_at}} = read.(c, [@policy])
      assert %{policy: %{count: 1, free_at: nil}} = read.(a, [@policy])

      wait = DateTime.diff(free_at, DateTime.utc_now(), :millisecond)
      assert wait > 50_000 and wait <= 60_000
    end

    test "PC-50: members older than the window no longer count", %{
      scope: scope,
      recipient: recipient
    } do
      short = %{@policy | window_ms: 300}

      read = fn ->
        FrequencyCounter.read(scope, recipient, Relay.Id.generate(), [short], real())
      end

      assert :ok = FrequencyCounter.record(scope, recipient, Relay.Id.generate(), [short], real())
      assert %{policy: %{count: 1}} = read.()
      Process.sleep(400)
      assert %{policy: %{count: 0}} = read.()
    end

    test "PC-50: the sliding set frees a slot when the oldest member leaves the window", %{
      scope: scope
    } do
      path = ["fq", "t", Relay.Id.to_string(Relay.Id.generate())]
      count = &Relay.Platform.sliding_set_count(scope, path, 60_000, &1, &2, real())

      for member <- ["a", "b", "c"] do
        assert {:ok, _} = Relay.Platform.sliding_set_add(scope, path, 60_000, member, real())
      end

      assert {:ok, %{count: 3, free_at_ms: free_at, now_ms: now}} = count.("d", 3)
      assert free_at - now > 59_000 and free_at - now <= 60_000
      assert {:ok, %{count: 2, free_at_ms: nil}} = count.("a", 3)
      assert {:ok, %{count: 2, free_at_ms: shifted}} = count.("a", 2)
      assert shifted >= free_at
    end
  end

  defp real, do: [backend: __MODULE__.Unstarted]

  defp await_valkey(0), do: flunk("Valkey is not reachable")

  defp await_valkey(n) do
    if Valkey.ping() == :ok,
      do: :ok,
      else:
        (
          Process.sleep(50)
          await_valkey(n - 1)
        )
  end
end
