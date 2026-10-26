defmodule RelayDev.Credo.ChecksTest do
  use Credo.Test.Case

  alias RelayDev.Credo.{
    BareProcess,
    BinaryCopy,
    EtsTables,
    LaneOutsideLane,
    LimitClock,
    MailboxRules,
    NoDirectClock,
    OffHeapMailbox,
    PersistentTerm,
    PublicApiDocs,
    RepoOutsideStore,
    RestartBudget,
    TenantProcesses,
    TodoWithIssue,
    UnsafeConversion,
    VirtualOffset
  }

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  defp issues(code, check, filename \\ "lib/relay/example.ex") do
    code |> to_source_file(filename) |> run_check(check)
  end

  describe "T-57 no direct clock or randomness" do
    test "T-57: wall clock, monotonic time and :rand calls are reported" do
      code = """
      defmodule Relay.Example do
        def a, do: DateTime.utc_now()
        def b, do: System.monotonic_time()
        def c, do: :rand.uniform(10)
        def d, do: Enum.random([1, 2])
      end
      """

      assert length(issues(code, NoDirectClock)) == 4
    end

    test "T-57: the ports themselves are allowed" do
      code = "defmodule Relay.Example do\n  def a, do: Relay.Clock.utc_now()\nend\n"
      assert issues(code, NoDirectClock) == []
    end
  end

  describe "INV-16 T-31 lane derivation" do
    test "INV-16: a clause mapping a message class to a lane is reported" do
      code = """
      defmodule Relay.Example do
        def lane(:security), do: :l0
        def queue(class), do: case(class, do: (:marketing -> "l3"; _ -> "l2"))
      end
      """

      assert length(issues(code, LaneOutsideLane)) == 2
    end

    test "T-31: asking the lane module, or using a lane on its own, is allowed" do
      code = """
      defmodule Relay.Example do
        def lane(class), do: Relay.Platform.lane(class)
        def budget(:l2), do: 10
        def secure?(:security), do: true
      end
      """

      assert issues(code, LaneOutsideLane) == []
    end
  end

  describe "TP-3 DS-40 OP-34 unsafe conversion" do
    test "TP-3: evaluation, atom creation and unsafe decoding are reported" do
      code = """
      defmodule Relay.Example do
        def a(s), do: Code.eval_string(s)
        def b(s), do: String.to_atom(s)
        def c(s), do: EEx.eval_string(s)
        def d(b), do: :erlang.binary_to_term(b)
        def e(s), do: Jason.decode(s, keys: :atoms)
        def f(s), do: Code.string_to_quoted(s)
      end
      """

      assert length(issues(code, UnsafeConversion)) == 6
    end

    test "DS-40: existing-atom conversion is allowed" do
      code = "defmodule Relay.Example do\n  def a(s), do: String.to_existing_atom(s)\nend\n"
      assert issues(code, UnsafeConversion) == []
    end
  end

  describe "T-47 bare processes" do
    test "T-47: Task, spawn and Task.Supervisor calls are reported" do
      code = """
      defmodule Relay.Example do
        def a, do: Task.start(fn -> :ok end)
        def b, do: spawn(fn -> :ok end)
        def c, do: Task.async(fn -> :ok end)
        def d, do: Task.Supervisor.async_nolink(S, fn -> :ok end)
      end
      """

      assert length(issues(code, BareProcess)) == 4
    end

    test "T-47: Relay.Process is allowed" do
      code =
        "defmodule Relay.Example do\n  def a, do: Relay.Process.start_task(fn -> :ok end)\nend\n"

      assert issues(code, BareProcess) == []
    end
  end

  describe "T-58 code quality" do
    test "T-58: Repo calls outside a store are reported" do
      code =
        "defmodule Relay.Example do\n  def a, do: Relay.Repo.all(X)\n  def b, do: Repo.one(X)\nend\n"

      assert length(issues(code, RepoOutsideStore)) == 2
      assert issues(code, RepoOutsideStore, "lib/relay/ingest/store.ex") == []
    end

    test "T-58: a TODO without an issue is reported" do
      code =
        "defmodule Relay.Example do\n  # TODO fix this\n  # TODO(#12): fix this\n  def a, do: :ok\nend\n"

      assert [%{line_no: 2}] = issues(code, TodoWithIssue)
    end

    test "T-58: public functions need @doc and @spec unless they implement a callback" do
      code = """
      defmodule Relay.Example do
        @moduledoc "Example."

        @doc "Documented."
        @spec a() :: :ok
        def a, do: :ok

        def b, do: :ok

        @impl true
        def c, do: :ok

        @doc false
        def d, do: :ok

        defp e, do: :ok
      end
      """

      assert [%{message: message}] = issues(code, PublicApiDocs)
      assert message =~ "b/0 is missing @doc and @spec"
    end
  end

  describe "T-45 process and memory rules" do
    test "T-45: global mailbox placement and killing a process are reported" do
      code = """
      defmodule Relay.Example do
        def a, do: :erlang.system_flag(:message_queue_data, :off_heap)
        def b(pid), do: Process.exit(pid, :kill)
        def c, do: Process.flag(:max_heap_size, %{size: 1, kill: true})
        def d, do: :erlang.system_flag(:max_heap_size, %{size: 1, kill: true})
      end
      """

      assert length(issues(code, MailboxRules)) == 4
    end

    test "T-45: per-process placement and a non-killing heap limit are allowed" do
      code = """
      defmodule Relay.Example do
        def a, do: Process.flag(:message_queue_data, :off_heap)
        def b, do: :erlang.system_flag(:max_heap_size, %{size: 1, kill: false})
        def c(pid), do: Process.exit(pid, :normal)
      end
      """

      assert issues(code, MailboxRules) == []
    end

    test "T-45: a listed bursty-mailbox process must set its mailbox off heap" do
      without = "defmodule Relay.Example do\n  def init(s), do: {:ok, s}\nend\n"

      with_flag = """
      defmodule Relay.Example do
        def init(s) do
          Process.flag(:message_queue_data, :off_heap)
          {:ok, s}
        end
      end
      """

      assert [_] = issues(without, OffHeapMailbox)
      assert issues(with_flag, OffHeapMailbox) == []
    end

    test "T-45: copying a binary outside Relay.Binary is reported" do
      code = "defmodule Relay.Example do\n  def a(b), do: :binary.copy(b)\nend\n"
      assert [_] = issues(code, BinaryCopy)

      keep = "defmodule Relay.Example do\n  def a(b), do: Relay.Binary.keep(b)\nend\n"
      assert issues(keep, BinaryCopy) == []
    end

    test "T-45: a supervisor without a stated restart budget is reported" do
      code = """
      defmodule Relay.Example do
        def a(c), do: Supervisor.init(c, strategy: :one_for_one)
        def b(c), do: Supervisor.start_link(c, strategy: :one_for_one, name: X)
        def c, do: DynamicSupervisor.init(strategy: :one_for_one)
        def d(c), do: Supervisor.init(c, strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
        def e, do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
      end
      """

      assert length(issues(code, RestartBudget)) == 3
    end

    test "T-45: an ETS table named at run time is reported" do
      code = """
      defmodule Relay.Example do
        @table :examples
        def a(tenant), do: :ets.new(tenant, [:set])
        def b, do: :ets.new(:examples, [:set])
        def c, do: :ets.new(__MODULE__, [:set])
        def d, do: :ets.new(@table, [:set])
      end
      """

      assert [%{line_no: 3}] = issues(code, EtsTables)
    end

    test "T-45: persistent_term writes are reported outside the reviewed publishers" do
      code = """
      defmodule Relay.Example do
        def a, do: :persistent_term.put(:k, 1)
        def b, do: :persistent_term.erase(:k)
        def c, do: :persistent_term.get(:k)
      end
      """

      assert length(issues(code, PersistentTerm)) == 2
    end

    test "T-45: dynamic children start only through Relay.TenantWorker" do
      code = """
      defmodule Relay.Example do
        def a(spec), do: DynamicSupervisor.start_child(S, spec)
        def b(t), do: Relay.TenantWorker.ensure(t, :apns, {W, idle_ms: 1})
      end
      """

      assert [%{line_no: 2}] = issues(code, TenantProcesses)
    end
  end

  describe "T-11 limiter clock" do
    test "T-11: limiter code never reads the node's wall clock" do
      code = """
      defmodule Relay.Example do
        def a, do: Relay.Clock.utc_now()
        def b, do: DateTime.utc_now()
        def c, do: NaiveDateTime.utc_now()
        def d, do: Relay.Clock.monotonic_ms()
      end
      """

      assert length(issues(code, LimitClock)) == 3
    end
  end

  describe "TN-8 X-27 virtual clock offset" do
    test "TN-8: reading the virtual offset outside Relay.Clock.Virtual is reported" do
      code = ~S'''
      defmodule Relay.Example do
        alias Relay.Clock.VirtualStore
        def a(scope), do: Relay.Clock.Virtual.offset_ms(scope)
        def b, do: Repo.call!("relay_fn.virtual_clock_get", [])
        def c, do: "SELECT offset_ms FROM relay.virtual_clocks"
      end
      '''

      assert [2, 3, 4, 5] = code |> issues(VirtualOffset) |> Enum.map(& &1.line_no) |> Enum.sort()
    end

    test "X-27: business time through Relay.Clock is allowed" do
      code = """
      defmodule Relay.Example do
        def a(scope), do: Relay.Clock.business_now(scope)
        def b(scope, at), do: Relay.Clock.wall_time(scope, at)
      end
      """

      assert issues(code, VirtualOffset) == []
    end
  end
end
