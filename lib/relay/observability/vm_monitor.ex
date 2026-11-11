defmodule Relay.Observability.VmMonitor do
  @moduledoc """
  The node's own VM system monitor. It registers with `:erlang.system_monitor/2` for long garbage collections and schedules (100 ms), large heaps (16 M words), long message queues (on at 10 000, off at 5 000 messages) and busy ports, and turns every report into `[:relay, :vm, :monitor]` telemetry with `%{count, value}` and `%{kind, process}`. The process label is the registered name or the initial call, never a raw process identifier. The monitor runs at high priority with its mailbox off the heap so that it keeps reporting while the node is under pressure. `sample/0` is the periodic VM measurement: memory, process, port and atom counts and limits and the dirty scheduler run queues, as `[:relay, :vm, :sample]`.
  """

  use GenServer

  @long_ms 100
  @large_heap_words 16_000_000
  @long_queue {5_000, 10_000}

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # T-48
  # T-53 (2)
  @doc "Emits one periodic VM sample; called by the telemetry poller."
  @spec sample() :: :ok
  def sample do
    memory = :erlang.memory()
    [dirty_cpu, dirty_io] = Enum.take(:erlang.statistics(:run_queue_lengths_all), -2)

    measurements = %{
      memory_total: memory[:total],
      memory_processes: memory[:processes],
      memory_binary: memory[:binary],
      memory_ets: memory[:ets],
      memory_atom: memory[:atom],
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      port_limit: :erlang.system_info(:port_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      run_queue: :erlang.statistics(:total_run_queue_lengths),
      dirty_cpu_run_queue: dirty_cpu,
      dirty_io_run_queue: dirty_io
    }

    :telemetry.execute([:relay, :vm, :sample], measurements, %{})
  end

  # T-48
  @doc "The label of a process or port: its registered name, its initial call or its driver name."
  @spec label(pid() | port()) :: String.t()
  def label(pid) when is_pid(pid) do
    case Process.info(pid, [:registered_name, :dictionary, :initial_call]) do
      nil -> "exited"
      info -> registered(info[:registered_name], info)
    end
  end

  def label(port) when is_port(port) do
    case :erlang.port_info(port, :name) do
      {:name, name} -> "port:" <> List.to_string(name)
      :undefined -> "port:closed"
    end
  end

  # T-48
  @impl GenServer
  def init(nil) do
    Process.flag(:priority, :high)
    Process.flag(:message_queue_data, :off_heap)

    _previous =
      :erlang.system_monitor(self(), [
        {:long_gc, @long_ms},
        {:long_schedule, @long_ms},
        {:large_heap, @large_heap_words},
        {:long_message_queue, @long_queue},
        :busy_port,
        :busy_dist_port
      ])

    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:monitor, target, kind, info}, state) do
    report(kind, target, info)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp report(:long_message_queue, _target, false), do: :ok

  defp report(kind, target, info) do
    meta = %{kind: kind, process: label(target)}
    :telemetry.execute([:relay, :vm, :monitor], %{count: 1, value: value(kind, info)}, meta)
  end

  defp value(kind, info) when kind in [:long_gc, :long_schedule] and is_list(info),
    do: Keyword.get(info, :timeout, 0)

  defp value(:large_heap, info) when is_list(info), do: Keyword.get(info, :heap_size, 0)
  defp value(_kind, _info), do: 1

  defp registered(name, _info) when is_atom(name) and name != nil, do: inspect(name)
  defp registered(_none, info), do: initial(info)

  defp initial(info) do
    call =
      case List.keyfind(info[:dictionary] || [], :"$initial_call", 0) do
        {_key, mfa} -> mfa
        nil -> info[:initial_call]
      end

    case call do
      {module, function, arity} -> Exception.format_mfa(module, function, arity)
      _unknown -> "unknown"
    end
  end
end
