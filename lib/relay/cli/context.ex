defmodule Relay.CLI.Context do
  @moduledoc """
  What one run of the command line tool works with: its IO devices, environment variables, the injected HTTP options, sleep, time and randomness, whether a prompt may be shown, the output mode and the resolved configuration.
  """

  alias Relay.CLI.Config

  defstruct [
    :stdout,
    :stderr,
    :stdin,
    :env,
    :http,
    :sleep,
    :random_bytes,
    :now,
    :max_polls,
    :command,
    :config,
    interactive?: false,
    json?: false,
    yes?: false
  ]

  @type t :: %__MODULE__{
          stdout: IO.device(),
          stderr: IO.device(),
          stdin: IO.device(),
          env: %{optional(String.t()) => String.t()},
          http: keyword(),
          sleep: (non_neg_integer() -> term()),
          random_bytes: (pos_integer() -> binary()),
          now: (-> DateTime.t()),
          max_polls: pos_integer() | nil,
          command: String.t() | nil,
          config: Config.t() | nil,
          interactive?: boolean(),
          json?: boolean(),
          yes?: boolean()
        }

  @doc "Builds the context of a run from the options of `Relay.CLI.run/2`."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    %__MODULE__{
      stdout: Keyword.get(opts, :stdout, :stdio),
      stderr: Keyword.get(opts, :stderr, :stderr),
      stdin: Keyword.get(opts, :stdin, :stdio),
      env: Keyword.get_lazy(opts, :env, &System.get_env/0),
      http: Keyword.get(opts, :http, []),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      random_bytes: Keyword.get(opts, :random_bytes, &Relay.Random.bytes/1),
      now: Keyword.get(opts, :now, &Relay.Clock.utc_now/0),
      max_polls: Keyword.get(opts, :max_polls),
      interactive?: Keyword.get(opts, :interactive?, false)
    }
  end

  # X-33
  @doc "Returns true when standard input is a terminal, so a live-plane change may be confirmed at a prompt."
  @spec interactive?() :: boolean()
  def interactive? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> List.keyfind(opts, :stdin, 0) == {:stdin, true}
      _error -> false
    end
  end
end
