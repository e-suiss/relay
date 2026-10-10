defmodule RelayDev.Credo.BareProcess do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check:
        "Background work starts only through `Relay.Process`, which carries trace context and the correlation id (T-47)."
    ]

  @message "start background work through Relay.Process (T-47)"

  @rules [
    {Task, :start, @message},
    {Task, :start_link, @message},
    {Task, :async, @message},
    {Task, :async_stream, @message},
    {Task.Supervisor, :start_child, @message},
    {Task.Supervisor, :async, @message},
    {Task.Supervisor, :async_nolink, @message},
    {Task.Supervisor, :async_stream, @message},
    {Task.Supervisor, :async_stream_nolink, @message},
    {Process, :spawn, @message},
    {Kernel, :spawn, @message},
    {Kernel, :spawn_link, @message},
    {Kernel, :spawn_monitor, @message},
    {:erlang, :spawn, @message},
    {:erlang, :spawn_link, @message},
    {:proc_lib, :spawn, @message},
    {:proc_lib, :spawn_link, @message},
    {nil, :spawn, @message},
    {nil, :spawn_link, @message},
    {nil, :spawn_monitor, @message}
  ]

  # T-47
  @impl true
  def run(%SourceFile{} = source_file, params),
    do: RelayDev.Credo.Calls.issues(source_file, params, __MODULE__, @rules)
end
