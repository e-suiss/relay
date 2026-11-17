defmodule Relay.Agents.A2a do
  @moduledoc """
  The A2A face of an agent's mailbox and of incoming task notifications (AG-42, E-51, L-28): the wire shapes of the protocol version the mapping table names (`Relay.AgentProtocols`), and nothing that delivers. Delivery, retries, signatures, the dead letter state, replay and the address rules are the delivery engine's.

  Outgoing, a push notification is the wake hint of a mailbox record (AG-21) written as an A2A `StreamResponse` holding one `statusUpdate`. For the event of a waitpoint the task is the waitpoint and its state is what the mapping table says A2A sees of it; a state the table leaves unchanged or to the owner is sent as `TASK_STATE_UNSPECIFIED`, with the rule in the metadata, so Relay never claims a task state it does not own. For any other record the task is the mailbox. The notification carries the record's durable handle and position and neither content nor sender: the record waits in the mailbox whether or not the push arrives (INV-35).

  Incoming, `notification/1` reads a `StreamResponse` into the task it names, the state it reports and its sequence number (AG-37): the `seq` of the event's metadata when the sender gives one, otherwise the microsecond timestamp of the status, so two notifications of one task are always ordered. `task/1` reads the answer of `GetTask`, the source a notification is reconciled with.
  """

  alias Relay.AgentProtocols
  alias Relay.Agents.TaskStore

  @unspecified "TASK_STATE_UNSPECIFIED"
  @states ~w(TASK_STATE_UNSPECIFIED TASK_STATE_SUBMITTED TASK_STATE_WORKING TASK_STATE_COMPLETED
             TASK_STATE_FAILED TASK_STATE_CANCELED TASK_STATE_INPUT_REQUIRED TASK_STATE_REJECTED
             TASK_STATE_AUTH_REQUIRED)
  @task_ref ~r/\A[\x21-\x7e]{1,256}\z/

  @type push :: %{
          endpoint_id: Relay.Id.t(),
          record_id: Relay.Id.t(),
          mailbox_id: Relay.Id.t(),
          epoch: pos_integer(),
          seq: pos_integer(),
          occurred_at: DateTime.t(),
          data: map()
        }
  @type notification :: %{task: String.t(), seq: non_neg_integer(), state: String.t() | nil}

  # AG-42
  @doc "The task states of the protocol as they are written in JSON."
  @spec states() :: [String.t(), ...]
  def states, do: @states

  # AG-42
  # AG-21
  # AG-5
  @doc "The push notification of a mailbox record inside the caller's scoped transaction: the A2A push endpoint of the active agent that owns the mailbox and the `StreamResponse` to send it. `nil` when the mailbox is no agent's, the agent is not active or has no A2A push endpoint, or the record is unknown."
  @spec push_in(Relay.Id.t(), Relay.Id.t()) :: push() | nil
  def push_in(<<_::128>> = mailbox_id, <<_::128>> = record_id) do
    case TaskStore.push_row(mailbox_id, record_id) do
      nil -> nil
      row -> push(row)
    end
  end

  defp push(row) do
    %{
      endpoint_id: row["endpoint_id"],
      record_id: row["record_id"],
      mailbox_id: row["mailbox_id"],
      epoch: row["epoch"],
      seq: row["seq"],
      occurred_at: row["created_at"],
      data: status_update(row)
    }
  end

  # AG-42
  # AG-46
  # INV-35
  @doc "The `StreamResponse` of a mailbox record: one `statusUpdate` with the task, the state the mapping table gives it and the record's handle and position under `metadata.relay`."
  @spec status_update(map()) :: map()
  def status_update(row) do
    mailbox = Relay.ExternalId.encode("mbx", row["mailbox_id"])
    {task, rule, state} = task_state(row, mailbox)

    %{
      "statusUpdate" => %{
        "taskId" => task,
        "contextId" => mailbox,
        "status" => %{"state" => state, "timestamp" => DateTime.to_iso8601(row["created_at"])},
        "metadata" => %{
          "seq" => row["seq"],
          "relay" => %{
            "mailbox_id" => mailbox,
            "record_id" => Relay.ExternalId.encode("mbr", row["record_id"]),
            "epoch" => row["epoch"],
            "seq" => row["seq"],
            "kind" => row["kind"],
            "event_type" => row["event_type"],
            "rule" => rule
          }
        }
      }
    }
  end

  defp task_state(%{"waitpoint_id" => <<_::128>> = id, "waitpoint_state" => state} = row, _box)
       when is_binary(state) do
    waitpoint = %{state: state, kind: row["waitpoint_kind"], profile: row["waitpoint_profile"]}
    task = Relay.ExternalId.encode("wp", id)

    case AgentProtocols.of(AgentProtocols.bundled(), :a2a, waitpoint) do
      {:ok, %{rule: :state, state: task_state}} -> {task, "state", task_state}
      {:ok, %{rule: rule}} -> {task, Atom.to_string(rule), @unspecified}
      :error -> {task, "unchanged", @unspecified}
    end
  end

  defp task_state(_row, mailbox), do: {mailbox, "hint", @unspecified}

  # AG-42
  # AG-37
  @doc "Reads a decoded `StreamResponse` as a task notification: exactly one of `task`, `statusUpdate`, `artifactUpdate` and `message`, the task it names, its sequence number and the state it reports (`nil` when the event carries none). Anything else is `:error`."
  @spec notification(term()) :: {:ok, notification()} | :error
  def notification(%{} = body) when map_size(body) == 1 do
    case body do
      %{"statusUpdate" => %{"taskId" => task, "status" => %{} = status} = event} ->
        read(task, state(status), seq(event, status))

      %{"task" => %{"id" => task, "status" => %{} = status} = event} ->
        read(task, state(status), seq(event, status))

      %{"artifactUpdate" => %{"taskId" => task} = event} ->
        read(task, {:ok, nil}, seq(event, %{}))

      %{"message" => %{"taskId" => task} = event} ->
        read(task, {:ok, nil}, seq(event, %{}))

      _other ->
        :error
    end
  end

  def notification(_other), do: :error

  defp read(task, {:ok, state}, {:ok, seq}) when is_binary(task) do
    if Regex.match?(@task_ref, task),
      do: {:ok, %{task: task, seq: seq, state: state}},
      else: :error
  end

  defp read(_task, _state, _seq), do: :error

  defp state(%{"state" => state}) when state in @states, do: {:ok, state}
  defp state(_status), do: :error

  defp seq(%{"metadata" => %{"seq" => seq}}, _status) when is_integer(seq) and seq >= 0,
    do: {:ok, seq}

  defp seq(%{"metadata" => %{"seq" => _other}}, _status), do: :error

  defp seq(_event, %{"timestamp" => text}) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> {:ok, max(DateTime.to_unix(at, :microsecond), 0)}
      {:error, _reason} -> :error
    end
  end

  defp seq(_event, _status), do: :error

  # AG-42
  # INV-35
  @doc "Reads the answer of `GetTask`, a `Task` object, as the state of the task at its source and its sequence number; `:error` when it is none."
  @spec task(term()) :: {:ok, notification()} | :error
  def task(%{"id" => _task, "status" => _status} = task), do: notification(%{"task" => task})
  def task(_other), do: :error

  # AG-42
  # E-50
  @doc "Checks the `A2A-Version` values of a request against the versions Relay serves: exactly one value, in the form `Major.Minor`. A request without the header is refused, since an empty value means a version before 1.0."
  @spec version([String.t()]) :: {:ok, String.t()} | {:error, :version_not_supported}
  def version([value]) when is_binary(value) do
    if AgentProtocols.served?(AgentProtocols.bundled(), "a2a", value),
      do: {:ok, value},
      else: {:error, :version_not_supported}
  end

  def version(_missing_or_many), do: {:error, :version_not_supported}
end
