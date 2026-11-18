defmodule Relay.Platform.Maintenance.ArchiveTask do
  @moduledoc """
  The `partition_archive` singleton task: the archive role's half of the partition life cycle (hot, detached, cold). Each step takes the oldest detached leaf that `partition_maintenance` handed off and moves it to the cold archive with `Relay.Platform.Maintenance.Archive`; one leaf at a time, never two at once, as the fencing token of the task's lease guards every manifest write and the removal of the hot copy. A failed attempt leaves the leaf detached and is retried from scratch on a later step.

  The task remembers when it first saw each waiting leaf and reports the age of the oldest one, so a stuck archive raises an alarm even when no attempt fails.

  Configuration under `config :relay, Relay.Platform.Maintenance.ArchiveTask`: `:store`, the options of the in-region object-locked archive bucket (`Relay.ObjectStore.S3`).

  Telemetry: `[:relay, :archive, :archived]` (`rows`, `bytes`; `table`), `[:relay, :archive, :failure]` (`table`, `code`) and `[:relay, :archive, :state]` (`failures`, the consecutive failed attempts; `backlog`, the leaves waiting; `backlog_age_s`, the age of the oldest).
  """

  @behaviour Relay.Platform.Leadership

  require Logger

  alias Relay.Platform.Maintenance.Archive
  alias Relay.Platform.Maintenance.ArchiveStore

  @idle_ms 15 * 60_000
  @busy_ms 60_000

  # OP-15
  # OP-84
  # DS-44
  # INV-47
  @impl Relay.Platform.Leadership
  @doc "Runs one archive step."
  @spec run(Relay.Platform.Leadership.context()) :: Relay.Platform.Leadership.step()
  def run(%{fencing_token: token, state: saved}) do
    saved = saved || %{}
    now = Relay.Clock.utc_now()

    with {:ok, leaves} <- ArchiveStore.leaves() do
      backlog = backlog(Map.get(saved, "backlog", %{}), leaves, now)
      failures = Map.get(saved, "failures", 0)
      {failures, remaining} = step(leaves, token, failures)
      backlog = Map.take(backlog, remaining)
      report(failures, backlog, now)
      delay = if remaining == [] or failures > 0, do: @idle_ms, else: @busy_ms
      {:ok, %{"backlog" => backlog, "failures" => failures}, delay}
    end
  end

  defp step([], _token, _failures), do: {0, []}

  defp step([leaf | rest], token, failures) do
    names = Enum.map(rest, & &1.leaf_name)

    case Archive.run(leaf, token, store()) do
      {:ok, archived} ->
        :telemetry.execute(
          [:relay, :archive, :archived],
          %{rows: archived.rows, bytes: archived.bytes},
          %{table: leaf.table_name}
        )

        {0, names}

      {:error, %Relay.Error{code: code}} ->
        :telemetry.execute([:relay, :archive, :failure], %{count: 1}, %{
          table: leaf.table_name,
          code: code
        })

        Logger.warning("archive attempt failed", table: leaf.table_name, code: code)
        {failures + 1, [leaf.leaf_name | names]}
    end
  end

  @doc "Merges the first-seen times of the waiting leaves: a leaf seen before keeps its time, a new one takes `now`."
  @spec backlog(map(), [ArchiveStore.leaf()], DateTime.t()) :: %{String.t() => String.t()}
  def backlog(seen, leaves, %DateTime{} = now) do
    Map.new(leaves, fn %{leaf_name: name} ->
      {name, Map.get_lazy(seen, name, fn -> DateTime.to_iso8601(now) end)}
    end)
  end

  @doc "Age in seconds of the oldest waiting leaf; 0 without one."
  @spec backlog_age(%{String.t() => String.t()}, DateTime.t()) :: non_neg_integer()
  def backlog_age(backlog, %DateTime{} = now) do
    backlog
    |> Map.values()
    |> Enum.map(fn seen ->
      {:ok, at, _} = DateTime.from_iso8601(seen)
      max(DateTime.diff(now, at), 0)
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp report(failures, backlog, now) do
    :telemetry.execute(
      [:relay, :archive, :state],
      %{failures: failures, backlog: map_size(backlog), backlog_age_s: backlog_age(backlog, now)},
      %{}
    )
  end

  # OP-84
  @doc "The options of the archive store, from `config :relay, Relay.Platform.Maintenance.ArchiveTask, store: …`."
  @spec store() :: keyword()
  def store, do: :relay |> Application.get_env(__MODULE__, []) |> Keyword.get(:store, [])
end
