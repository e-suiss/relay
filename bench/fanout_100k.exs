# T-89
# T-23
defmodule RelayBench.FanoutSource do
  @moduledoc false
  @behaviour Relay.Platform.FanoutSource

  @impl true
  def page(_scope, fanout, position, range_to, limit) do
    ids = :persistent_term.get({__MODULE__, fanout.source_id})
    first = start_index(ids, position)
    last = min(first + limit, tuple_size(ids)) - 1

    if first > last,
      do: [],
      else: for(n <- first..last, id = elem(ids, n), range_to == nil or id < range_to, do: id)
  end

  @impl true
  def process(_scope, _fanout, ids), do: {length(ids), 0}

  defp start_index(_ids, {:from, nil}), do: 0
  defp start_index(ids, {:from, first}), do: search(ids, &(&1 >= first))
  defp start_index(ids, {:after, last}), do: search(ids, &(&1 > last))

  defp search(ids, past?), do: search(ids, past?, 0, tuple_size(ids))

  defp search(_ids, _past?, low, high) when low >= high, do: low

  defp search(ids, past?, low, high) do
    mid = div(low + high, 2)

    if past?.(elem(ids, mid)),
      do: search(ids, past?, low, mid),
      else: search(ids, past?, mid + 1, high)
  end
end

defmodule RelayBench.Fanout100k do
  @moduledoc false

  alias Relay.Platform.Fanout
  alias Relay.Platform.FanoutSlice

  @recipients 100_000
  @slice 5_000

  def run do
    Application.put_env(:relay, Fanout, sources: %{"bench" => RelayBench.FanoutSource})
    scope = RelayTest.TenantFixture.tenant!().live
    source = Relay.Id.generate()
    ids = for ms <- 1..@recipients, do: Relay.Id.build(ms, :crypto.strong_rand_bytes(10))
    :persistent_term.put({RelayBench.FanoutSource, source}, List.to_tuple(ids))
    bounds = [nil | ids |> Enum.drop(@slice) |> Enum.take_every(@slice)] ++ [nil]
    id = Relay.Id.generate()

    {create_us, {:ok, {:created, ^id, slices}}} =
      :timer.tc(fn ->
        Fanout.create(scope, %{
          id: id,
          source_kind: "bench",
          source_id: source,
          lane: :l1,
          bounds: bounds,
          recipient_count: @recipients
        })
      end)

    %{rows: jobs} =
      Relay.Repo.query!(
        "SELECT args FROM relay_queue.oban_jobs WHERE worker = $1 AND args->>'fanout_id' = $2",
        ["Relay.Platform.FanoutSlice", Relay.Id.to_string(id)]
      )

    {run_us, results} =
      :timer.tc(fn ->
        jobs
        |> Task.async_stream(
          fn [args] ->
            FanoutSlice.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})
          end,
          max_concurrency: System.schedulers_online(),
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    {:ok, progress} = Fanout.get(scope, id)
    true = Enum.all?(results, &(&1 == :ok))
    %{state: "completed", processed_count: @recipients} = progress

    IO.puts("""
    fanout_100k
      recipients: #{@recipients}
      slices: #{slices} (#{length(jobs)} jobs)
      create_ms: #{div(create_us, 1_000)}
      slices_ms: #{div(run_us, 1_000)}
      recipients_per_s: #{div(@recipients * 1_000_000, max(run_us, 1))}
    """)
  end
end

RelayBench.Fanout100k.run()
