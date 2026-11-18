defmodule Mix.Tasks.Relay.Acceptance do
  @shortdoc "Runs the region acceptance suite against a Relay base URL"
  @moduledoc """
  Runs `RelayDev.Acceptance` (OP-58 (7), OP-93) and writes its report: `mix relay.acceptance [--dev] [--report PATH]`.

  The target and its credentials come from the environment, never from arguments, and are never printed: `ACCEPTANCE_BASE_URL`; `ACCEPTANCE_TOKEN` with `ACCEPTANCE_DPOP_SEED` (the base64 Ed25519 seed the token is bound to); optionally `ACCEPTANCE_OTHER_TOKEN` with `ACCEPTANCE_OTHER_DPOP_SEED` of a second tenant; `ACCEPTANCE_WORKFLOW` and `ACCEPTANCE_RECIPIENT` of the drill (default `welcome` and `dev-sample-recipient`); `ACCEPTANCE_FAILOVER_COMMAND` and `ACCEPTANCE_RESTORE_COMMAND`; `TOXIPROXY_URL` for the chaos step. With `--dev` the suite talks to the local test plane on `ACCEPTANCE_BASE_URL` (default `http://localhost:4000`) as the trusted proxy of `https://localhost` and uses the sample client of `mix relay.dev.seed`. The report is JSON with the time of every step; the task fails when a step failed.
  """

  use Mix.Task
  use Boundary, classify_to: RelayDev

  # OP-93
  # OP-58
  @impl true
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [dev: :boolean, report: :string])
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)
    config = config(Keyword.get(opts, :dev, false))
    report = RelayDev.Acceptance.run(config)
    path = Keyword.get(opts, :report, "acceptance-report.json")

    document =
      Map.merge(report, %{
        target: URI.parse(config.public_url).host,
        finished_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    File.write!(path, Jason.encode_to_iodata!(document, pretty: true))

    for step <- report.steps,
        do: Mix.shell().info("#{step.name}: #{step.status} in #{step.ms} ms")

    unless report.passed, do: Mix.raise("relay.acceptance: a step failed; see #{path}")
  end

  defp config(dev?) do
    base = env("ACCEPTANCE_BASE_URL") || default_base(dev?)

    %{
      base_url: String.trim_trailing(base, "/"),
      public_url: if(dev?, do: "https://localhost", else: String.trim_trailing(base, "/")),
      headers: headers(dev?),
      auth: auth(dev?, "ACCEPTANCE_TOKEN", "ACCEPTANCE_DPOP_SEED"),
      other: other(),
      workflow: env("ACCEPTANCE_WORKFLOW") || "welcome",
      recipient: env("ACCEPTANCE_RECIPIENT") || "dev-sample-recipient",
      failover_command: env("ACCEPTANCE_FAILOVER_COMMAND"),
      restore_command: env("ACCEPTANCE_RESTORE_COMMAND"),
      toxiproxy: env("TOXIPROXY_URL")
    }
  end

  defp default_base(true), do: "http://localhost:4000"
  defp default_base(false), do: Mix.raise("ACCEPTANCE_BASE_URL is required")

  defp headers(true), do: [{"x-forwarded-proto", "https"}, {"x-forwarded-host", "localhost"}]
  defp headers(false), do: []

  defp auth(true, _token, _seed) do
    token = RelayDev.Seed.token()
    %{token: token, proof: &RelayDev.Access.proof(&1, &2, token)}
  end

  defp auth(false, token_name, seed_name) do
    token = env(token_name) || Mix.raise("#{token_name} is required")
    seed = env(seed_name) || Mix.raise("#{seed_name} is required")
    %{token: token, proof: RelayDev.Acceptance.ed25519_proof(Base.decode64!(seed), token)}
  end

  defp other do
    if env("ACCEPTANCE_OTHER_TOKEN"),
      do: auth(false, "ACCEPTANCE_OTHER_TOKEN", "ACCEPTANCE_OTHER_DPOP_SEED")
  end

  defp env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
