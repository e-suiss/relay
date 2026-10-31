defmodule Relay.CLI.Command do
  @moduledoc """
  Behaviour of a command group of the command line tool. A command returns its JSON-ready result with the readable lines to print, or a failure.
  """

  @type result :: {:ok, term(), [String.t()]} | {:error, Relay.CLI.Failure.t()}

  @doc "Runs the command with the resolved configuration in the context."
  @callback run(Relay.CLI.Context.t(), Relay.CLI.Args.t()) :: result()
end
