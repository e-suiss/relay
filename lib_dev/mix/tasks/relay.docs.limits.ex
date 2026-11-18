defmodule Mix.Tasks.Relay.Docs.Limits do
  @shortdoc "Renders the limits, retry schedules and guarantees page"
  @moduledoc """
  Renders the "limits, retry schedules, guarantees" documentation page as Markdown to `OUT_PATH` (`RelayDev.LimitsPage`). With `--check` it writes nothing and fails when `OUT_PATH` differs from the page the sources render. Options: `--root PATH`, `--check`.
  """

  use Mix.Task
  use Boundary, classify_to: RelayDev

  # X-37
  # X-49
  # API-4
  @impl true
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: [root: :string, check: :boolean])
    root = Keyword.get(opts, :root, File.cwd!())

    out =
      case paths do
        [out] -> out
        _other -> Mix.raise("usage: mix relay.docs.limits [--check] [--root PATH] OUT_PATH")
      end

    page = RelayDev.LimitsPage.render(root)

    if Keyword.get(opts, :check, false) do
      check(out, page)
    else
      File.mkdir_p!(Path.dirname(out))
      File.write!(out, page)
      Mix.shell().info("relay.docs.limits: wrote #{out}")
    end
  end

  defp check(out, page) do
    case File.read(out) do
      {:ok, ^page} -> Mix.shell().info("relay.docs.limits: #{out} is current")
      {:ok, _stale} -> Mix.raise("#{out} is stale; run mix relay.docs.limits #{out}")
      {:error, _reason} -> Mix.raise("#{out} is missing; run mix relay.docs.limits #{out}")
    end
  end
end
