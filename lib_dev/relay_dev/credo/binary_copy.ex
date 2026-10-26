defmodule RelayDev.Credo.BinaryCopy do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      A part of a large binary kept beyond the request is copied at the retention boundary through `Relay.Binary.keep/1`, which documents the refc binary playbook (T-45 (2)); copying whole binaries wholesale is not a fix.
      """
    ]

  @message "keep binary parts through Relay.Binary.keep/1 at the retention boundary (T-45 (2))"

  # T-45 (2)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    RelayDev.Credo.ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {:binary, :copy, _args} -> @message
        _ -> nil
      end
    ])
  end
end
