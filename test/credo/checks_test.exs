defmodule RelayDev.Credo.ChecksTest do
  use Credo.Test.Case

  alias RelayDev.Credo.{
    BareProcess,
    NoDirectClock,
    PublicApiDocs,
    RepoOutsideStore,
    TodoWithIssue,
    UnsafeConversion
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
end
