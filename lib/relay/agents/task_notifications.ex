defmodule Relay.Agents.TaskNotifications do
  @moduledoc """
  The recorded state of the tasks that registered sources notify Relay about (AG-37, AG-42, INV-35, E-51). A notification is a hint that a task changed, never the record of the task: the task lives at its source and belongs to whoever waits for it.

  For each task of a source Relay keeps the highest sequence number it has applied and the state reported with it. `record/2` moves that record forward in one transaction: a notification with the sequence number already applied is a `duplicate`, one with a lower number is `stale` and changes nothing, so a notification that arrives late never overwrites a newer one. Only an applied notification appends `agent.task_notification_received` to the outbox, in the same transaction.

  `reconcile/3` reads the task again at its source when a notification cannot be trusted to carry the current state: it arrived out of order, or it names no state. The read goes through the reader configured as `config :relay, Relay.Agents, task_reader: Module`, which answers the source's `GetTask`; what it reports is applied under the same rule. Without a reader nothing is read and the recorded state stands.
  """

  alias Relay.Agents.A2a
  alias Relay.Repo
  alias Relay.Scope

  @results [:applied, :duplicate, :stale, :source_not_found]

  @type attrs :: %{
          required(:source_id) => Relay.Id.t(),
          required(:task) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:state) => String.t() | nil,
          optional(:receipt_id) => Relay.Id.t() | nil,
          optional(:reconciled) => boolean()
        }
  @type result :: :applied | :duplicate | :stale | :source_not_found

  @doc "Reads a task at its source: the decoded answer of the source's `GetTask`."
  @callback get_task(Scope.t(), source_id :: Relay.Id.t(), task :: String.t()) ::
              {:ok, map()} | {:error, term()}

  # AG-37
  # INV-35
  @doc "Applies a task notification in a transaction of its own; see the module documentation."
  @spec record(Scope.t(), attrs()) :: {:ok, result()} | {:error, term()}
  def record(%Scope{} = scope, %{source_id: source_id, task: task, seq: seq} = attrs) do
    params = [
      source_id,
      task,
      "a2a",
      seq,
      Map.get(attrs, :state),
      Map.get(attrs, :receipt_id),
      Map.get(attrs, :reconciled, false)
    ]

    Repo.in_scope(scope, fn _status ->
      [row] = Repo.call!("relay_fn.agent_task_notification_apply", params)
      Repo.code!(row["result"], @results)
    end)
  end

  # AG-37
  @doc "Reads the recorded state of a task of a source: its `seq`, `state`, when it was last reconciled and when it changed; `nil` for a task no notification named."
  @spec get(Scope.t(), Relay.Id.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get(%Scope{} = scope, source_id, task) do
    sql = """
    SELECT n.task, n.protocol, n.seq, n.state, n.reconciled_at, n.updated_at
    FROM relay.agent_task_notifications n
    WHERE n.source_id = $1 AND n.task = $2
    """

    Repo.in_scope(scope, fn _status ->
      case Repo.scoped_query!(sql, [source_id, task]) do
        %{rows: [row], columns: columns} -> columns |> Enum.zip(row) |> Map.new()
        %{rows: []} -> nil
      end
    end)
  end

  # AG-42
  # INV-35
  @doc "Reads a task again at its source and applies what the source reports; `:unconfigured` without a reader, `:unreadable` when the answer is no task."
  @spec reconcile(Scope.t(), Relay.Id.t(), String.t()) ::
          {:ok, result() | :unconfigured | :unreadable} | {:error, term()}
  def reconcile(%Scope{} = scope, source_id, task) do
    case reader() do
      nil -> {:ok, :unconfigured}
      module -> read(scope, source_id, task, module.get_task(scope, source_id, task))
    end
  end

  defp read(scope, source_id, task, {:ok, body}) do
    case A2a.task(body) do
      {:ok, %{task: ^task, seq: seq, state: state}} ->
        attrs = %{source_id: source_id, task: task, seq: seq, state: state, reconciled: true}
        record(scope, attrs)

      _other ->
        {:ok, :unreadable}
    end
  end

  defp read(_scope, _source_id, _task, {:error, reason}), do: {:error, reason}

  defp reader do
    :relay |> Application.get_env(Relay.Agents, []) |> Keyword.get(:task_reader)
  end
end
