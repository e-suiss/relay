defmodule Relay.Hygiene do
  @moduledoc """
  Process-side secret hygiene. A process that holds credentials or unwrapped keys is marked sensitive, so tracing, back-traces and `Process.info/2` of its messages and dictionary show nothing; its `format_status/1` replaces the secret parts of its state, the message being handled, the debug log and the arguments in a crash reason's stack trace before any crash report or `:sys.get_status/1` sees them.
  """

  @marker :redacted

  # T-46
  @doc """
  Declares the secret fields of a struct: `use Relay.Hygiene, secret_fields: [:field]` after `@derive {Inspect, only: [...]}` and `defstruct`. Every build, the release build included, inspects a struct carrying a marker in each secret field and fails to compile the module if the marker shows.
  """
  defmacro __using__(opts) do
    fields = Keyword.fetch!(opts, :secret_fields)

    quote do
      Module.register_attribute(__MODULE__, :relay_secret_fields, persist: true)
      @relay_secret_fields unquote(fields)
      @after_compile Relay.Hygiene
    end
  end

  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok
  def __after_compile__(env, _bytecode) do
    fields = env.module.__info__(:attributes) |> Keyword.get_values(:relay_secret_fields)

    case check_inspect(env.module, List.flatten(fields)) do
      :ok ->
        :ok

      {:error, message} ->
        raise CompileError, file: env.file, line: env.line, description: message
    end
  end

  # T-46
  @doc "Checks that inspecting a struct of `module` shows none of its secret fields."
  @spec check_inspect(module(), [atom()]) :: :ok | {:error, String.t()}
  def check_inspect(module, [_ | _] = fields) do
    marker = "relay-secret-marker-5e1f0c2a"
    struct = struct(module, Map.new(fields, &{&1, marker}))

    cond do
      Inspect.impl_for(struct) == Inspect.Any ->
        {:error, "#{inspect(module)} holds secrets and needs @derive {Inspect, only: [...]}"}

      inspect(struct, limit: :infinity, printable_limit: :infinity) =~ marker ->
        {:error, "inspecting #{inspect(module)} shows a secret field"}

      true ->
        :ok
    end
  end

  def check_inspect(module, []), do: {:error, "#{inspect(module)} declares no secret fields"}

  # T-46
  @doc "Marks the calling process as sensitive."
  @spec sensitive!() :: :ok
  def sensitive! do
    _ = Process.flag(:sensitive, true)
    :ok
  end

  @doc "Builds a `format_status/1` result: `redact_state` rewrites the state; the message, the debug log and the queue are replaced and stack trace arguments in the reason are pruned."
  @spec format_status(map(), (term() -> term())) :: map()
  def format_status(status, redact_state) when is_map(status) and is_function(redact_state, 1) do
    status
    |> update(:state, redact_state)
    |> update(:message, fn _ -> @marker end)
    |> update(:log, fn _ -> [] end)
    |> update(:queue, fn _ -> [] end)
    |> update(:reason, &prune_reason/1)
  end

  @doc "Replaces the arguments of every stack trace frame with their count."
  @spec prune_stacktrace(Exception.stacktrace() | term()) :: Exception.stacktrace() | term()
  def prune_stacktrace(stacktrace) when is_list(stacktrace), do: Enum.map(stacktrace, &frame/1)
  def prune_stacktrace(other), do: other

  @doc "Prunes the stack trace and the exception arguments of an exit reason."
  @spec prune_reason(term()) :: term()
  def prune_reason({exception, stacktrace}) when is_list(stacktrace),
    do: {exception(exception), prune_stacktrace(stacktrace)}

  def prune_reason({:shutdown, _} = reason), do: reason
  def prune_reason(reason), do: exception(reason)

  @doc "Returns true for a stack trace frame that still carries its arguments."
  @spec frame_with_args?(term()) :: boolean()
  def frame_with_args?({module, function, args, location})
      when is_atom(module) and is_atom(function) and is_list(args) and is_list(location),
      do: true

  def frame_with_args?(_term), do: false

  defp frame({module, function, args, location} = entry) do
    if frame_with_args?(entry), do: {module, function, length(args), location}, else: entry
  end

  defp frame(entry), do: entry

  defp exception(%FunctionClauseError{} = error), do: %{error | args: nil}
  defp exception(%BadFunctionError{} = error), do: %{error | term: @marker}
  defp exception(%MatchError{} = error), do: %{error | term: @marker}
  defp exception(%CaseClauseError{} = error), do: %{error | term: @marker}
  defp exception(%WithClauseError{} = error), do: %{error | term: @marker}
  defp exception({:badmatch, _}), do: {:badmatch, @marker}
  defp exception({:case_clause, _}), do: {:case_clause, @marker}
  defp exception({:function_clause, _}), do: :function_clause
  defp exception(other), do: other

  defp update(map, key, fun) do
    case map do
      %{^key => value} -> Map.put(map, key, fun.(value))
      _ -> map
    end
  end
end
