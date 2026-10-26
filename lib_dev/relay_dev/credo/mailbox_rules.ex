defmodule RelayDev.Credo.MailboxRules do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Mailboxes are unbounded and backpressure is application code (T-45 (1), (4)). Mailbox data placement is set per process with `Process.flag(:message_queue_data, ...)`, never globally. A growing mailbox is an escalation signal, not a reason to kill: killing a process, directly or through a killing heap limit, loses its messages.
      """
    ]

  @global "set mailbox placement per process, not globally (T-45 (1))"
  @kill "do not kill a process to shed its mailbox; apply backpressure (T-45 (4))"

  # T-45 (1)
  # T-45 (4)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    RelayDev.Credo.ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {:erlang, :system_flag, [:message_queue_data | _]} -> @global
        {Process, :exit, [_pid, :kill]} -> @kill
        {:erlang, :exit, [_pid, :kill]} -> @kill
        {Process, :flag, [:max_heap_size, opts]} -> if kills?(opts), do: @kill
        {:erlang, :process_flag, [:max_heap_size, opts]} -> if kills?(opts), do: @kill
        {:erlang, :system_flag, [:max_heap_size, opts]} -> if kills?(opts), do: @kill
        _ -> nil
      end
    ])
  end

  defp kills?({:%{}, _, pairs}), do: Enum.any?(pairs, &match?({:kill, true}, &1))
  defp kills?(_opts), do: false
end
