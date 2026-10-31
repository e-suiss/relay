defmodule Relay.CLI.Confirm do
  @moduledoc """
  Confirmation of a change to the live plane. A command that changes `live` runs only with `--yes` (or `--confirm-live`) or after the person answers `y` at a prompt on a terminal; otherwise it stops with exit code 8 before anything is sent.
  """

  alias Relay.CLI.Config
  alias Relay.CLI.Context
  alias Relay.CLI.Failure

  # X-33
  # X-42
  @doc "Returns `:ok` when the change may go ahead: the environment is `test`, `--yes` was given, or the prompt was answered `y`."
  @spec live(Context.t(), Config.environment(), String.t()) :: :ok | {:error, Failure.t()}
  def live(%Context{}, :test, _action), do: :ok
  def live(%Context{yes?: true}, :live, _action), do: :ok

  def live(%Context{interactive?: true} = ctx, :live, action) do
    IO.write(ctx.stderr, "#{action} in the live environment. Continue? [y/N] ")

    case IO.gets(ctx.stdin, "") do
      answer when is_binary(answer) ->
        if String.downcase(String.trim(answer)) in ["y", "yes"],
          do: :ok,
          else: refused("the live change was not confirmed")

      _eof ->
        refused("the live change was not confirmed")
    end
  end

  def live(%Context{}, :live, action),
    do: refused("#{action} in the live environment; confirm with --yes or --confirm-live")

  defp refused(message), do: {:error, Failure.new(:not_confirmed, "live_not_confirmed", message)}
end
