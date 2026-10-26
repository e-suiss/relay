defmodule RelayDev.Credo.PersistentTerm do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      `:persistent_term` holds large terms that change rarely. Every write or erase triggers a global garbage collection, so writes are allowed only in the reviewed modules excluded in `.credo.exs`, which publish at start or on rare state changes (T-45 (5)). Frequently changing data goes to ETS or a process.
      """
    ]

  @message "persistent_term writes trigger a global GC; only reviewed rare-change publishers may write (T-45 (5))"

  # T-45 (5)
  @impl true
  def run(%SourceFile{} = source_file, params) do
    RelayDev.Credo.ProcessRules.issues(source_file, params, __MODULE__, [
      fn
        {:persistent_term, fun, _args} when fun in [:put, :erase] -> @message
        _ -> nil
      end
    ])
  end
end
