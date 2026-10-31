defmodule Relay.CLI.Output do
  @moduledoc """
  Output of the command line tool. Readable text goes to standard output and errors to standard error. With `--json` the result is one JSON object on standard output, `{"exit_code": 0, "command": ..., "result": ...}` or `{"exit_code": n, "command": ..., "error": {...}}`; a polling command first prints one JSON object per line for each item (`{"type": ..., "data": ...}`) and ends with the result object.
  """

  alias Relay.CLI.Command
  alias Relay.CLI.Context
  alias Relay.CLI.ExitCode
  alias Relay.CLI.Failure

  # X-33
  # X-42
  @doc "Prints the result of a command and returns its exit code."
  @spec finish(Context.t(), Command.result()) :: ExitCode.t()
  def finish(%Context{} = ctx, {:ok, data, lines}) do
    if ctx.json? do
      json(ctx, %{"exit_code" => 0, "command" => ctx.command, "result" => data})
    else
      Enum.each(lines, &IO.puts(ctx.stdout, &1))
    end

    ExitCode.code(:ok)
  end

  def finish(%Context{} = ctx, {:error, %Failure{} = failure}) do
    code = ExitCode.code(failure.kind)

    if ctx.json? do
      error = Failure.to_map(failure)
      json(ctx, %{"exit_code" => code, "command" => ctx.command, "error" => error})
    else
      Enum.each(Failure.lines(failure), &IO.puts(ctx.stderr, &1))
    end

    code
  end

  # X-33
  @doc "Prints one item of a polling command: a JSON line with `--json`, otherwise the readable line."
  @spec item(Context.t(), String.t(), term(), String.t()) :: :ok
  def item(%Context{} = ctx, type, data, line) do
    if ctx.json? do
      json(ctx, %{"type" => type, "data" => data})
    else
      IO.puts(ctx.stdout, line)
    end
  end

  @doc "Prints a warning on standard error."
  @spec warn(Context.t(), String.t()) :: :ok
  def warn(%Context{} = ctx, message), do: IO.puts(ctx.stderr, "warning: " <> message)

  defp json(ctx, map), do: IO.puts(ctx.stdout, Jason.encode!(map))
end
