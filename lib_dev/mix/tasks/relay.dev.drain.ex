defmodule Mix.Tasks.Relay.Dev.Drain do
  @shortdoc "Sends test plane traffic through a node restart and checks that no accepted event was lost"
  @moduledoc """
  The traffic side of the nightly deploy test (`RelayDev.Drain`). `mix relay.dev.drain traffic --base URL --seconds N --rate R --out FILE` sends events and records the accepted ones; `mix relay.dev.drain verify --base URL --out FILE --timeout S` fails unless every recorded event reached its notifications. It only reads the configuration, so it runs next to a running node.
  """

  use Mix.Task
  use Boundary, classify_to: RelayDev

  @switches [base: :string, seconds: :integer, rate: :integer, out: :string, timeout: :integer]

  # OP-87
  # T-5
  @impl true
  def run([command | args]) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:req)
    base = Keyword.get(opts, :base, "http://127.0.0.1:4000")
    out = Keyword.fetch!(opts, :out)
    command(command, base, out, opts)
  end

  def run(_args), do: Mix.raise("usage: mix relay.dev.drain traffic|verify --out FILE")

  defp command("traffic", base, out, opts) do
    counts = RelayDev.Drain.traffic(base, opts[:seconds] || 60, opts[:rate] || 20, out)
    Mix.shell().info("drain traffic: #{inspect(counts)}")
    if counts.accepted == 0, do: Mix.raise("no event was accepted")
  end

  defp command("verify", base, out, opts) do
    accepted = out |> File.read!() |> String.split("\n", trim: true) |> length()

    case RelayDev.Drain.verify(base, out, opts[:timeout] || 180) do
      [] ->
        Mix.shell().info("drain verify: #{accepted} accepted, accepted but not enqueued 0")

      lost ->
        Mix.raise(
          "drain verify: #{accepted} accepted, accepted but not enqueued #{length(lost)}: " <>
            Enum.join(lost, " ")
        )
    end
  end

  defp command(other, _base, _out, _opts), do: Mix.raise("unknown command #{other}")
end
