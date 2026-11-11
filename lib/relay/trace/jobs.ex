defmodule Relay.Trace.Jobs do
  @moduledoc """
  Trace context across the job queue. `opts/1` adds the current `traceparent` and `correlation_id` to the metadata of a job being built (`Relay.Worker` calls it from `new/2`); when the job starts, its process takes the correlation id and a child span of that context (a new trace when the job carries none), and when it stops, the span is recorded with the queue, worker, attempt and result.
  """

  @handler {__MODULE__, :jobs}
  @span {__MODULE__, :span}
  @events [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]]

  # OP-34
  # T-63 (2)
  @doc "Adds the current trace context and correlation id to a job's `:meta` option."
  @spec opts(keyword()) :: keyword()
  def opts(opts) do
    metadata = Logger.metadata()

    context =
      %{"traceparent" => Relay.Trace.current(), "correlation_id" => metadata[:correlation_id]}
      |> Map.filter(fn {_key, value} -> is_binary(value) end)

    if context == %{}, do: opts, else: Keyword.update(opts, :meta, context, &Map.merge(context, &1))
  end

  # OP-34
  @doc "Attaches the job handlers once; a second call leaves them attached."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # OP-34
  # T-63 (2)
  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event([:oban, :job, :start], _measurements, %{job: job}, _config) do
    meta = job.meta || %{}

    case meta["correlation_id"] do
      id when is_binary(id) -> Logger.metadata(correlation_id: id)
      _none -> :ok
    end

    parent = meta["traceparent"]
    traceparent = Relay.Trace.child(parent)
    :ok = Relay.Trace.put(traceparent)
    Process.put(@span, {traceparent, Relay.Trace.span_id(parent), Relay.Clock.utc_now()})
    :ok
  end

  def handle_event([:oban, :job, event], _measurements, %{job: job} = meta, _config)
      when event in [:stop, :exception] do
    case Process.delete(@span) do
      {traceparent, parent_span_id, started_at} ->
        Relay.Trace.record(%{
          name: "job " <> job.worker,
          kind: :consumer,
          traceparent: traceparent,
          parent_span_id: parent_span_id,
          started_at: started_at,
          ended_at: Relay.Clock.utc_now(),
          attributes: %{
            "relay.queue" => job.queue,
            "relay.worker" => job.worker,
            "relay.attempt" => job.attempt,
            "relay.result" => to_string(Map.get(meta, :state, event))
          },
          links: [],
          error?: event == :exception
        })

      nil ->
        :ok
    end
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
