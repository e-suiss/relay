defmodule Relay.WorkerTest do
  use ExUnit.Case, async: true

  alias Relay.Worker

  defmodule DefaultWorker do
    use Relay.Worker, queue: :default

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  defmodule ShortWorker do
    use Relay.Worker, queue: :default, max_attempts: 3, timeout: 30_000

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  defp compile(name, opts) do
    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use Relay.Worker, unquote(opts)

          @impl Oban.Worker
          def perform(%Oban.Job{}), do: :ok
        end
      end
    )
  end

  describe "T-15 job timeout" do
    test "T-15: a worker without a timeout runs for at most one hour" do
      assert Worker.max_timeout_ms() == 3_600_000
      assert DefaultWorker.timeout(%Oban.Job{}) == 3_600_000
    end

    test "T-15: a worker keeps its shorter timeout and its Oban options" do
      assert ShortWorker.timeout(%Oban.Job{attempt: 5}) == 30_000
      assert ShortWorker.__opts__()[:max_attempts] == 3
      assert ShortWorker.__opts__()[:queue] == :default
      assert ShortWorker.__relay_worker__()
    end

    test "T-15: the base worker is exported by the shared kernel, so every context can use it" do
      [definition] = Keyword.fetch!(Relay.__info__(:attributes), Boundary)
      assert Worker in Enum.map(definition.opts[:exports], &Module.safe_concat(Relay, &1))
    end

    test "OP-69: a timeout above one hour does not compile" do
      assert_raise ArgumentError, ~r/from 1 to 3600000 milliseconds/, fn ->
        compile(TooLongWorker, queue: :default, timeout: 3_600_001)
      end
    end

    test "OP-69: a zero, infinite or computed timeout does not compile" do
      for {name, timeout} <- [
            {ZeroWorker, 0},
            {InfiniteWorker, :infinity},
            {ComputedWorker, quote(do: :timer.hours(2))}
          ] do
        assert_raise ArgumentError, fn -> compile(name, queue: :default, timeout: timeout) end
      end
    end
  end
end
