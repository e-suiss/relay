defmodule Relay.CLI do
  @moduledoc """
  The `relay` command line tool. It is a client of the public Relay HTTP API for local development, workflow files, previews, logs and kill switches: it signs in with an Access access token obtained with the OAuth 2.0 client credentials grant and never reaches server internals.

  `main/1` is the escript entry point; `run/2` parses the arguments, runs one command and returns its exit code. Every command prints either readable text or, with `--json`, one JSON object that carries an `exit_code` field.
  """

  use Boundary, top_level?: true, deps: [Relay], exports: []

  alias Relay.CLI.Args
  alias Relay.CLI.Config
  alias Relay.CLI.Context
  alias Relay.CLI.ExitCode
  alias Relay.CLI.Failure
  alias Relay.CLI.Output
  alias Relay.CLI.Token

  @commands %{
    "trigger" => Relay.CLI.Trigger,
    "preview" => Relay.CLI.Preview,
    "pull" => Relay.CLI.Workflows,
    "push" => Relay.CLI.Workflows,
    "promote" => Relay.CLI.Workflows,
    "logs" => Relay.CLI.Logs,
    "listen" => Relay.CLI.Listen,
    "kill-switch" => Relay.CLI.KillSwitch
  }

  # X-33
  # X-42
  @doc "Escript entry point: runs the command line and halts the VM with its exit code."
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {:ok, _apps} = Application.ensure_all_started([:ssl, :req])
    :logger.set_primary_config(:level, :emergency)
    System.halt(run(argv, interactive?: Context.interactive?()))
  end

  # X-33
  # X-42
  @doc """
  Runs one command line and returns its exit code.

  Options: `:env` (environment variables, by default those of the process), `:stdout`, `:stderr` and `:stdin` (IO devices), `:interactive?` (whether a live-plane change may be confirmed at a prompt, default `false`), `:http` (Req options merged into every request), `:sleep` (a function taking milliseconds), `:random_bytes` (a function returning that many random bytes), `:now` (a function returning the current UTC time) and `:max_polls` (polling commands stop after that many polls).
  """
  @spec run([String.t()], keyword()) :: ExitCode.t()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    ctx = Context.new(opts)
    Token.forget_all()

    case Args.parse(argv) do
      {:help, text} ->
        IO.write(ctx.stdout, text)
        ExitCode.code(:ok)

      {:error, message, json?} ->
        failure = Failure.new(:usage, "usage_error", message)
        Output.finish(%{ctx | json?: json?}, {:error, failure})

      {:ok, %Args{} = args} ->
        ctx = %{ctx | json?: args.json?, yes?: args.yes?, command: Args.label(args)}
        result = execute(ctx, args)
        Token.forget_all()
        Output.finish(ctx, result)
    end
  end

  defp execute(ctx, %Args{} = args) do
    module = Map.fetch!(@commands, args.command)
    mode = if args.command == "promote", do: :promote, else: :selected

    case Config.load(args.opts, ctx.env, mode) do
      {:ok, config} -> module.run(%{ctx | config: config}, args)
      {:error, %Failure{}} = error -> error
    end
  rescue
    exception ->
      {:error, Failure.new(:unexpected, "unexpected_error", Exception.message(exception))}
  end
end
