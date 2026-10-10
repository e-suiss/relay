defmodule Relay.Process do
  @moduledoc """
  The only way to start background work. Every task carries the caller's logger metadata, and a correlation id is mandatory so that it survives process boundaries.
  """

  @supervisor Relay.TaskSupervisor

  # T-47
  # T-63
  @doc "Starts a supervised fire-and-forget task carrying the caller's context."
  @spec start_task((-> term())) :: DynamicSupervisor.on_start_child()
  def start_task(fun) when is_function(fun, 0) do
    Task.Supervisor.start_child(@supervisor, with_context(fun))
  end

  @doc "Starts a supervised, unlinked task carrying the caller's context; await it with `Task.yield/2`."
  @spec async((-> result)) :: Task.t() when result: term()
  def async(fun) when is_function(fun, 0) do
    Task.Supervisor.async_nolink(@supervisor, with_context(fun))
  end

  @doc "Returns the caller's context; raises if it has no correlation id."
  @spec context!() :: keyword()
  def context! do
    metadata = Logger.metadata()

    case Keyword.get(metadata, :correlation_id) do
      id when is_binary(id) and id != "" -> metadata
      _ -> raise ArgumentError, "background work requires a correlation_id in Logger metadata"
    end
  end

  defp with_context(fun) do
    metadata = context!()

    fn ->
      Logger.metadata(metadata)
      fun.()
    end
  end
end
