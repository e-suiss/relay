defmodule Relay.Trace.Exporter do
  @moduledoc """
  The span exporter: finished spans are cast to the exporter process, which keeps at most 2048 of them with its mailbox off the heap, and are sent to the region's OTLP collector (`config :relay, Relay.Trace, endpoint: url`) as OTLP/HTTP JSON on `/v1/traces`, at most 512 a request, every five seconds. Without an endpoint the exporter does not start and spans are dropped where they are recorded. A full buffer drops the span (`[:relay, :trace, :dropped]`); a failed request drops its batch (`[:relay, :trace, :export_failed]`). Tracing never blocks or fails the work it observes. `:http` in the same configuration passes options to `Req`.
  """

  use GenServer

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
  @doc "Hands a finished span to the exporter; drops it when the exporter is not running."
  @spec export(Relay.Trace.span()) :: :ok
  def export(span) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:span, span})
    end
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
    Process.flag(:message_queue_data, :off_heap)
    Process.send_after(self(), :flush, @flush_ms)
    {:ok, {[], 0}}
  end

  @impl GenServer
  def handle_cast({:span, _span}, {spans, @max}) do
    :telemetry.execute([:relay, :trace, :dropped], %{count: 1}, %{})
    {:noreply, {spans, @max}}
  end

  def handle_cast({:span, span}, {spans, size}), do: {:noreply, {[span | spans], size + 1}}

  @impl GenServer
  def handle_info(:flush, buffer) do
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, send_all(buffer)}
  end

  @impl GenServer
  def handle_call(:flush, _from, buffer), do: {:reply, :ok, send_all(buffer)}

  defp send_all({[], 0}), do: {[], 0}

  defp send_all({spans, _size}) do
    case endpoint() do
      nil ->
        :ok

      url ->
        spans |> Enum.reverse() |> Enum.chunk_every(@batch) |> Enum.each(&post(url, &1))
    end

    {[], 0}
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
