defmodule Relay.Worker do
  @moduledoc """
  Base of every Relay job worker. `use Relay.Worker` takes the `Oban.Worker` options plus `:timeout`, a literal number of milliseconds that defaults to and may not exceed one hour; the worker's `timeout/1` is fixed to that value and cannot be overridden. A job that needs longer is split into smaller jobs, and a long wait is a row with a timer, not a running job.

      defmodule Relay.Delivery.SendWorker do
        use Relay.Worker, queue: :l1, max_attempts: 10, timeout: 30_000

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"delivery_id" => id}}), do: ...
      end
  """

  @max_timeout_ms 3_600_000

  # T-15 (3)
  # OP-69 (5)
  @doc "Longest timeout, in milliseconds, a Relay job may run."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  # T-15 (3)
  # OP-69 (5)
  @doc "Validates a worker timeout: a positive integer of at most `max_timeout_ms/0`. Raises `ArgumentError` otherwise."
  @spec validate_timeout!(term()) :: pos_integer()
  def validate_timeout!(timeout)
      when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout_ms,
      do: timeout

  def validate_timeout!(timeout) do
    raise ArgumentError,
          "a Relay job worker timeout must be a literal integer from 1 to #{@max_timeout_ms} milliseconds, got: #{Macro.to_string(timeout)}"
  end

  defmacro __using__(opts) do
    {timeout, oban_opts} = Keyword.pop(opts, :timeout, @max_timeout_ms)
    timeout = validate_timeout!(timeout)

    quote location: :keep do
      use Oban.Worker, unquote(oban_opts)

      @after_compile Relay.Worker

      @impl Oban.Worker
      def timeout(%Oban.Job{}), do: unquote(timeout)

      @doc false
      def __relay_worker__, do: true
    end
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok
  def __after_compile__(%{module: module}, _bytecode) do
    _ = validate_timeout!(module.timeout(%Oban.Job{}))
    :ok
  end
end
