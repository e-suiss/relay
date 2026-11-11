defmodule Relay.Trace.Exporter do
  @moduledoc """
  The span exporter: finished spans wait in one public ETS table of at most 2048 spans and are sent to the region's OTLP collector (`config :relay, Relay.Trace, endpoint: url`) as OTLP/HTTP JSON on `/v1/traces`, at most 512 a request, every five seconds. Without an endpoint the exporter does not start and spans are dropped where they are recorded. A full buffer drops the span (`[:relay, :trace, :dropped]`); a failed request drops its batch (`[:relay, :trace, :export_failed]`). Tracing never blocks or fails the work it observes. `:http` in the same configuration passes options to `Req`.
  """

  use GenServer

  @buffer __MODULE__.Buffer
  @max 2048
  @batch 512
  @flush_ms 5_000
  @kinds %{internal: 1, server: 2, client: 3, producer: 4, consumer: 5}

  # OP-32
  @doc "The exporter as a child when an endpoint is configured; otherwise none."
  @spec children() :: [module()]
  def children, do: if(endpoint(), do: [__MODULE__], else: [])

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # OP-32
  @doc "Buffers a finished span; drops it when the exporter is not running or the buffer is full."
  @spec export(Relay.Trace.span()) :: :ok
  def export(span) do
    cond do
      :ets.whereis(@buffer) == :undefined ->
        :ok

      :ets.info(@buffer, :size) >= @max ->
        :telemetry.execute([:relay, :trace, :dropped], %{count: 1}, %{})

      true ->
        :ets.insert(@buffer, {:erlang.unique_integer([:monotonic]), span})
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # OP-32
  @doc "Sends the buffered spans now."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  # OP-32
  @doc "The OTLP/HTTP JSON request body of a batch of spans."
  @spec body([Relay.Trace.span()]) :: map()
  def body(spans) do
    scope = %{"scope" => %{"name" => "relay"}, "spans" => Enum.map(spans, &span/1)}
    resource = %{"attributes" => [attribute("service.name", "relay")]}
    %{"resourceSpans" => [%{"resource" => resource, "scopeSpans" => [scope]}]}
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@buffer, [:named_table, :public, :ordered_set, write_concurrency: true])
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, nil}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    :ok = send_all()
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, send_all(), state}

  defp send_all do
    case {take(), endpoint()} do
      {[], _endpoint} ->
        :ok

      {_spans, nil} ->
        :ok

      {spans, url} ->
        post(url, spans)
        if length(spans) == @batch, do: send_all(), else: :ok
    end
  end

  defp take do
    case :ets.select(@buffer, [{{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}], @batch) do
      {rows, _continuation} ->
        Enum.each(rows, fn {key, _span} -> :ets.delete(@buffer, key) end)
        Enum.map(rows, fn {_key, span} -> span end)

      :"$end_of_table" ->
        []
    end
  end

  defp post(endpoint, spans) do
    config = Application.get_env(:relay, Relay.Trace, [])
    url = String.trim_trailing(endpoint, "/") <> "/v1/traces"
    opts = [json: body(spans), receive_timeout: 5_000, retry: false]

    case Req.post(url, Keyword.merge(opts, Keyword.get(config, :http, []))) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      _failed ->
        :telemetry.execute([:relay, :trace, :export_failed], %{count: length(spans)}, %{})
    end
  end

  defp endpoint do
    case Application.get_env(:relay, Relay.Trace, [])[:endpoint] do
      url when is_binary(url) and url != "" -> url
      _none -> nil
    end
  end

  defp span(span) do
    {:ok, %{trace_id: trace, span_id: id}} = Relay.Trace.parse(span.traceparent)

    %{
      "traceId" => trace,
      "spanId" => id,
      "parentSpanId" => span.parent_span_id || "",
      "name" => span.name,
      "kind" => Map.fetch!(@kinds, span.kind),
      "startTimeUnixNano" => nanos(span.started_at),
      "endTimeUnixNano" => nanos(span.ended_at),
      "attributes" => Enum.map(span.attributes, fn {key, value} -> attribute(key, value) end),
      "links" => Enum.flat_map(span.links, &link/1),
      "status" => %{"code" => if(span.error?, do: 2, else: 1)}
    }
  end

  defp link(traceparent) do
    case Relay.Trace.parse(traceparent) do
      {:ok, %{trace_id: trace, span_id: id}} -> [%{"traceId" => trace, "spanId" => id}]
      :error -> []
    end
  end

  defp nanos(%DateTime{} = at), do: at |> DateTime.to_unix(:nanosecond) |> Integer.to_string()

  defp attribute(key, value) when is_binary(value),
    do: %{"key" => key, "value" => %{"stringValue" => value}}

  defp attribute(key, value) when is_boolean(value),
    do: %{"key" => key, "value" => %{"boolValue" => value}}

  defp attribute(key, value) when is_integer(value),
    do: %{"key" => key, "value" => %{"intValue" => Integer.to_string(value)}}
end
