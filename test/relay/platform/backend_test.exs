defmodule Relay.Platform.BackendTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mox

  alias Relay.Platform.Backend
  alias Relay.ValkeyMock

  setup :verify_on_exit!

  describe "T-9 backend state machine" do
    test "T-9: a node starts on Valkey and stays there without failures" do
      state = Backend.new()
      assert Backend.mode(state, 0, 60_000) == :valkey
      assert Backend.mode(state, 1_000_000, 0) == :valkey
    end

    test "T-9: a failure moves the node to PostgreSQL and a later failure keeps the start time" do
      state = Backend.failure(Backend.new(), 1_000)
      assert %Backend{phase: :pg, since: 1_000} = state
      assert Backend.mode(state, 1_000, 60_000) == :pg
      assert Backend.failure(state, 9_000) == state
    end

    test "INV-44: after recovery a key is dual until its own horizon has passed" do
      state = Backend.new() |> Backend.failure(1_000) |> Backend.recover(7_000)
      assert %Backend{phase: :valkey, recovered_at: 7_000} = state

      assert Backend.mode(state, 7_000, 2_000) == :dual
      assert Backend.mode(state, 8_999, 2_000) == :dual
      assert Backend.mode(state, 9_000, 2_000) == :valkey
      assert Backend.mode(state, 9_000, 120_000) == :dual
      assert Backend.mode(state, 7_000, 0) == :valkey
    end

    test "T-9: a failure during dual goes back to PostgreSQL" do
      state = Backend.new() |> Backend.failure(0) |> Backend.recover(6_000)
      state = Backend.failure(state, 6_500)
      assert Backend.mode(state, 6_500, 120_000) == :pg
      assert state.recovered_at == nil
    end

    test "T-9: recovery changes only a PostgreSQL state" do
      assert Backend.recover(Backend.new(), 5) == Backend.new()
    end

    test "T-9: an error or a reply slower than 250 ms counts as a failure" do
      assert Backend.failed?({:error, :closed}, 0)
      assert Backend.failed?({:ok, [1]}, 251)
      refute Backend.failed?({:ok, [1]}, 250)
    end

    test "T-9: without either backend the decision is a denial for one second" do
      assert Backend.deny_reason() == %{
               retry_after_ms: 1_000,
               rule_id: "rate_limit.backend_unavailable"
             }
    end
  end

  describe "T-9 backend server" do
    defp start(name, opts \\ []) do
      allow(ValkeyMock, self(), fn -> GenServer.whereis(name) end)

      start_supervised!(
        {Backend,
         Keyword.merge([name: name, adapter: ValkeyMock, hold_ms: 20, ping_ms: 10], opts)}
      )
    end

    defp sync(name), do: :sys.get_state(name)

    test "T-9: a failed Valkey call switches the node to PostgreSQL and PING brings it back as dual",
         %{test: name} do
      start(name)
      parent = self()

      assert Backend.current_mode(60_000, name) == :valkey

      expect(ValkeyMock, :command, fn ["PING"] ->
        {:error, %Redix.ConnectionError{reason: :closed}}
      end)

      expect(ValkeyMock, :command, fn ["PING"] ->
        send(parent, :pinged)
        {:ok, "PONG"}
      end)

      log =
        capture_log(fn ->
          assert {:error, :closed} = Backend.call_valkey(fn -> {:error, :closed} end, name)
          sync(name)
          assert Backend.current_mode(60_000, name) == :pg

          assert_receive :pinged, 1_000
          sync(name)
        end)

      assert log =~ "PostgreSQL"
      assert Backend.current_mode(60_000, name) == :dual
      assert Backend.current_mode(0, name) == :valkey
    end

    test "T-9: a successful call leaves the node on Valkey and returns the reply", %{test: name} do
      start(name)

      assert {:ok, [1, 2]} = Backend.call_valkey(fn -> {:ok, [1, 2]} end, name)
      sync(name)
      assert Backend.state(name) == Backend.new()
    end

    test "T-9: no PING is sent before the hold time", %{test: name} do
      start(name, hold_ms: 60_000)

      capture_log(fn ->
        Backend.report_failure(name)
        sync(name)
      end)

      assert Backend.current_mode(0, name) == :pg
    end
  end
end
