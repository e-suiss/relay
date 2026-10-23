defmodule RelayDev.Lint.WorkersTest do
  use ExUnit.Case, async: true

  import RelayDev.Fixture

  alias RelayDev.Lint.Workers

  @moduletag :tmp_dir

  defmodule BareWorker do
    @moduledoc false
    use Oban.Worker, queue: :test

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule MarkedWorker do
    @moduledoc false
    use Oban.Worker, queue: :test

    @doc false
    def __relay_worker__, do: true

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  describe "OP-69 (5) queue workers use the base worker" do
    test "OP-69: a worker built directly on Oban.Worker is rejected", %{tmp_dir: dir} do
      write!(dir, %{
        "lib/relay/delivery/send_worker.ex" =>
          "defmodule Relay.Delivery.SendWorker do\n  use Oban.Worker, queue: :deliveries\nend\n",
        "lib/relay/inbox/count_worker.ex" =>
          "defmodule Relay.Inbox.CountWorker do\n  @behaviour Oban.Worker\nend\n",
        "lib/relay/webhooks/pro_worker.ex" => "  use Oban.Pro.Worker\n"
      })

      violations = Workers.run(dir)
      assert rules(violations) == ["oban_worker", "oban_worker", "oban_worker"]

      assert Enum.map(violations, & &1.path) == [
               "lib/relay/delivery/send_worker.ex",
               "lib/relay/inbox/count_worker.ex",
               "lib/relay/webhooks/pro_worker.ex"
             ]
    end

    test "INV-55: workers on the base worker pass, and the base worker may use Oban.Worker", %{
      tmp_dir: dir
    } do
      write!(dir, %{
        "lib/relay/worker.ex" =>
          "defmodule Relay.Worker do\n  defmacro __using__(opts) do\n    quote do\n      use Oban.Worker, unquote(opts)\n    end\n  end\nend\n",
        "lib/relay/delivery/send_worker.ex" =>
          "defmodule Relay.Delivery.SendWorker do\n  use Relay.Worker, queue: :deliveries\nend\n",
        "lib/relay/ingest/accept.ex" => "  # the `Oban.Worker` that sends a delivery\n"
      })

      assert Workers.run(dir) == []
    end

    test "OP-69: workers outside lib are not the application's", %{tmp_dir: dir} do
      write!(dir, %{"test/support/fixture.ex" => "  use Oban.Worker, queue: :deliveries\n"})
      assert Workers.run(dir) == []
    end

    test "OP-69: a compiled worker without the base worker's marker is found" do
      assert Workers.compiled([BareWorker, MarkedWorker, Relay.Clock]) == [BareWorker]
    end

    test "OP-69: every compiled worker of the application uses the base worker" do
      {:ok, modules} = :application.get_key(:relay, :modules)
      lib = Path.join(File.cwd!(), "lib") <> "/"

      application =
        Enum.filter(modules, fn module ->
          source = module.module_info(:compile) |> Keyword.get(:source, ~c"") |> to_string()
          String.starts_with?(source, lib)
        end)

      assert application != []
      assert Workers.compiled(application) == []
    end
  end
end
