defmodule Mix.Tasks.Relay.Dev.LoadTargets do
  @shortdoc "Writes open-loop Vegeta targets for send acceptance on the local test plane"
  @moduledoc """
  Writes a Vegeta HTTP target file of `POST /v1/events` requests of the sample test plane API client (OP-93, T-84): `mix relay.dev.load_targets URL RATE SECONDS OUT`, where `URL` is the public base URL the node sees (it names the proofs' `htu`), `RATE` the requests per second and `SECONDS` the length of the run. Every request carries the sample client's DPoP-bound token, its own DPoP proof, whose `iat` is the second the open-loop run schedules it in, starting `--lead` seconds (default 20) from now, its own `Idempotency-Key` and the sample event body, written next to `OUT`. `--connect URL` sends the requests to another base URL than the public one, and `--header NAME:VALUE` adds a header to every request, such as the `X-Forwarded-Proto` a trusted proxy would set. Nothing secret is printed.
  """

  use Mix.Task
  use Boundary, classify_to: RelayDev

  # OP-93
  # T-84
  @impl true
  def run(args) do
    strict = [lead: :integer, header: :keep, connect: :string]
    {opts, positional} = OptionParser.parse!(args, strict: strict)

    case positional do
      [url, rate, seconds, out] ->
        Mix.Task.run("app.config")
        write(url, String.to_integer(rate), String.to_integer(seconds), out, opts)

      _ ->
        Mix.raise("usage: mix relay.dev.load_targets URL RATE SECONDS OUT")
    end
  end

  defp write(url, rate, seconds, out, opts) do
    base = String.trim_trailing(url, "/")
    target = base <> "/v1/events"
    connect = String.trim_trailing(Keyword.get(opts, :connect, base), "/") <> "/v1/events"
    body = Path.expand(Path.rootname(out) <> "-body.json")
    File.mkdir_p!(Path.dirname(Path.expand(out)))
    File.write!(body, Jason.encode!(RelayDev.Seed.sample_event()))
    token = RelayDev.Seed.token()
    start = DateTime.to_unix(Relay.Clock.utc_now()) + Keyword.get(opts, :lead, 20)
    headers = for {:header, header} <- opts, do: header <> "\n"

    targets =
      for n <- 0..(rate * seconds - 1) do
        proof = RelayDev.Access.proof_at("POST", target, token, start + div(n, rate))

        [
          "POST ",
          connect,
          "\nAuthorization: DPoP ",
          token,
          "\nDPoP: ",
          proof,
          "\nIdempotency-Key: load-",
          Integer.to_string(n),
          "-",
          Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          "\nContent-Type: application/json\n",
          headers,
          "@",
          body,
          "\n\n"
        ]
      end

    File.write!(out, targets)
    Mix.shell().info("relay.dev.load_targets: #{rate * seconds} requests in #{out}")
  end
end
