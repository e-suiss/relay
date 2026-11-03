defmodule Relay.Templates.Sandbox do
  @moduledoc """
  One render in its own process (TP-7, TP-49): spawned without a link and monitored, with a heap limit of 16 MB for email and 4 MB for other channels (shared binaries included) and a time budget of 50 ms for email and 10 ms for other channels. A process over its heap limit is killed by the runtime and the render is `output_too_large`; a process over its time budget is stopped and the render is `render_timeout`. Output over the channel's byte limit is refused, never cut.

  The time budgets are configurable under `config :relay, Relay.Templates.Sandbox` with `timeout_ms` and `email_timeout_ms`; one call may pass `:timeout_ms`, `:max_heap_bytes` and `:max_output_bytes`.

  Every successful render is measured: characters (code points), graphemes, bytes, whether the output is blank, and the fallback variables used (TP-14).
  """

  alias Relay.Templates.Context
  alias Relay.Templates.Engine

  @type reason ::
          :render_timeout
          | :output_too_large
          | {:missing_variable, String.t()}
          | {:schema_violation, String.t()}
  @type measures :: %{
          characters: non_neg_integer(),
          graphemes: non_neg_integer(),
          bytes: non_neg_integer(),
          blank: boolean(),
          fallbacks: non_neg_integer(),
          fallback_variables: [String.t()]
        }

  @email_heap 16 * 1024 * 1024
  @heap 4 * 1024 * 1024
  @email_timeout 50
  @timeout 10
  @email_output 1024 * 1024
  @output 256 * 1024

  # TP-7
  # TP-49
  @doc "The limits of one render on a channel: time budget, heap and output size."
  @spec limits(Context.channel(), keyword()) :: %{
          timeout_ms: pos_integer(),
          max_heap_bytes: pos_integer(),
          max_output_bytes: pos_integer()
        }
  def limits(channel, opts \\ []) do
    config = Application.get_env(:relay, __MODULE__, [])

    {timeout, heap, output} =
      if channel == :email,
        do: {Keyword.get(config, :email_timeout_ms, @email_timeout), @email_heap, @email_output},
        else: {Keyword.get(config, :timeout_ms, @timeout), @heap, @output}

    %{
      timeout_ms: Keyword.get(opts, :timeout_ms, timeout),
      max_heap_bytes: Keyword.get(opts, :max_heap_bytes, heap),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, output)
    }
  end

  # TP-7
  # TP-14
  # TP-41
  # TP-49
  @doc "Renders a template with a context built for `channel` inside a bounded process."
  @spec run(Engine.t(), Context.t(), Context.channel(), keyword()) ::
          {:ok, String.t(), measures()} | {:error, reason()}
  def run(template, context, channel, opts \\ [])

  def run(%Engine{} = template, %Context{channel: channel} = context, channel, opts) do
    limits = limits(channel, opts)
    parent = self()
    ref = make_ref()
    words = div(limits.max_heap_bytes, :erlang.system_info(:wordsize))
    heap = %{size: words, kill: true, error_logger: false, include_shared_binaries: true}

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(parent, {ref, Engine.render(template, context, channel)}) end,
        [:monitor, {:max_heap_size, heap}]
      )

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        finish(result, context, limits)

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :output_too_large}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:schema_violation, "the render failed"}}
    after
      limits.timeout_ms ->
        Process.exit(pid, :render_timeout)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :render_timeout}
    end
  end

  def run(%Engine{}, %Context{channel: built_for}, channel, _opts) do
    raise ArgumentError,
          "a context built for #{inspect(built_for)} cannot render for #{inspect(channel)}"
  end

  defp finish({:ok, output}, context, limits) do
    if byte_size(output) > limits.max_output_bytes,
      do: {:error, :output_too_large},
      else: {:ok, output, measure(output, context)}
  end

  defp finish({:error, reason}, _context, _limits), do: {:error, reason}

  # TP-7
  @doc "Measures a render output."
  @spec measure(String.t(), Context.t()) :: measures()
  def measure(output, %Context{fallbacks: fallbacks}) do
    %{
      characters: output |> String.codepoints() |> length(),
      graphemes: String.length(output),
      bytes: byte_size(output),
      blank: String.trim(output) == "",
      fallbacks: length(fallbacks),
      fallback_variables: Enum.uniq(fallbacks)
    }
  end
end
