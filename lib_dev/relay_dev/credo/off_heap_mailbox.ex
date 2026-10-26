defmodule RelayDev.Credo.OffHeapMailbox do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      The few processes with large, bursty mailboxes (HTTP pools, socket transports, the queue notifier) keep their mailbox off the process heap (T-45 (1)). The check runs on the files listed in `.credo.exs` and reports each one that does not call `Process.flag(:message_queue_data, :off_heap)`.
      """
    ]

  @message "this bursty-mailbox process must set Process.flag(:message_queue_data, :off_heap) (T-45 (1))"

  # T-45 (1)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    found =
      Credo.Code.prewalk(
        source_file,
        fn
          {{:., _, [{:__aliases__, _, [:Process]}, :flag]}, _, [:message_queue_data, :off_heap]} =
              ast,
          _acc ->
            {ast, true}

          ast, acc ->
            {ast, acc}
        end,
        false
      )

    if found do
      []
    else
      ctx = Credo.Check.Context.build(source_file, params, __MODULE__)
      [format_issue(ctx, message: @message, line_no: 1)]
    end
  end
end
