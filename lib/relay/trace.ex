defmodule Relay.Trace do
  @moduledoc """
  W3C trace context and spans. A trace context is a version `00` `traceparent` string; the current one lives in the process's logger metadata as `traceparent`, beside `trace_id` and `span_id`, so every log line carries them. Context crosses every boundary explicitly: the HTTP plug continues an incoming `traceparent` or starts a trace, a job carries the `traceparent` and `correlation_id` of the code that inserted it in its metadata (`Relay.Worker`), and records written to the ledger store the current context. A late provider event starts its own trace and links to the delivery's with a span link instead of keeping a span open.

  A finished span goes to `Relay.Trace.Exporter`, which sends it to the OTLP collector of the region when one is configured and drops it otherwise. Span attributes are limited to a fixed set of keys whose values are bounded and never personal data; any other key is dropped.
  """

  alias Relay.Trace.Exporter
  alias Relay.Trace.Jobs

  @pattern ~r/\A00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/
  @zero_trace String.duplicate("0", 32)
  @zero_span String.duplicate("0", 16)
  @attributes ~w(http.request.method http.response.status_code relay.operation relay.queue
                 relay.worker relay.attempt relay.channel relay.provider relay.class
                 relay.event_type relay.result relay.environment relay.correlation_id)

  @type t :: String.t()
  @type kind :: :internal | :server | :client | :producer | :consumer
  @type span :: %{
          name: String.t(),
          kind: kind(),
          traceparent: t(),
          parent_span_id: String.t() | nil,
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          attributes: %{String.t() => String.t() | integer() | boolean() | nil},
          links: [t()],
          error?: boolean()
        }

  # E-72
  # OP-34
  # T-63 (2)
  @doc "Parses a `traceparent`; `:error` for anything that is not a valid version `00` context."
  @spec parse(term()) :: {:ok, %{trace_id: String.t(), span_id: String.t()}} | :error
  def parse(value) when is_binary(value) do
    case Regex.run(@pattern, value) do
      [_, trace, span, _flags] when trace != @zero_trace and span != @zero_span ->
        {:ok, %{trace_id: trace, span_id: span}}

      _invalid ->
        :error
    end
  end

  def parse(_value), do: :error

  # OP-34
  @doc "True for a valid `traceparent`."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: parse(value) != :error

  # OP-34
  @doc "A context in a new trace."
  @spec new() :: t()
  def new, do: format(hex(16), hex(8))

  # OP-34
  @doc "A child context of `parent`: the same trace with a new span; a new trace when `parent` is not valid."
  @spec child(t() | nil) :: t()
  def child(parent) do
    case parse(parent) do
      {:ok, %{trace_id: trace}} -> format(trace, hex(8))
      :error -> new()
    end
  end

  # T-63 (2)
  @doc "The current context of this process, or nil."
  @spec current() :: t() | nil
  def current do
    value = Logger.metadata()[:traceparent]
    if valid?(value), do: value
  end

  # T-63 (2)
  # T-63 (3)
  @doc "Makes `traceparent` the current context; its trace and span identifiers join the logger metadata."
  @spec put(t()) :: :ok
  def put(traceparent) do
    {:ok, %{trace_id: trace, span_id: span}} = parse(traceparent)
    Logger.metadata(traceparent: traceparent, trace_id: trace, span_id: span)
  end

  # T-63 (2)
  @doc "The span identifier of a context, or nil."
  @spec span_id(t() | nil) :: String.t() | nil
  def span_id(traceparent) do
    case parse(traceparent) do
      {:ok, %{span_id: span}} -> span
      :error -> nil
    end
  end

  # E-72
  # T-63 (2)
  @doc "The headers that carry the current context to a webhook or event destination."
  @spec headers() :: [{String.t(), String.t()}]
  def headers do
    case current() do
      nil -> []
      traceparent -> [{"traceparent", traceparent}]
    end
  end

  # DS-40
  # OP-34
  @doc """
  Runs `fun` in a child span of the current context and records the span when it returns; the previous context is restored afterwards. `opts`: `:attributes`, `:kind` and `:links`, contexts of other traces the span links to.
  """
  @spec span(String.t(), keyword(), (-> result)) :: result when result: term()
  def span(name, opts \\ [], fun) when is_function(fun, 0) do
    parent = current()
    traceparent = child(parent)
    started_at = Relay.Clock.utc_now()
    :ok = put(traceparent)

    try do
      fun.()
    after
      record(%{
        name: name,
        kind: Keyword.get(opts, :kind, :internal),
        traceparent: traceparent,
        parent_span_id: span_id(parent),
        started_at: started_at,
        ended_at: Relay.Clock.utc_now(),
        attributes: Keyword.get(opts, :attributes, %{}),
        links: Keyword.get(opts, :links, []),
        error?: false
      })

      restore(parent)
    end
  end

  # DS-40
  # OP-34
  @doc "Records a finished span; attributes outside the fixed set and invalid links are dropped."
  @spec record(span()) :: :ok
  def record(span) do
    correlation = Logger.metadata()[:correlation_id]
    attributes = Map.put_new(span.attributes, "relay.correlation_id", correlation)
    attributes = Map.filter(attributes, &allowed?/1)
    links = Enum.filter(span.links, &valid?/1)
    Exporter.export(%{span | attributes: attributes, links: links})
  end

  # OP-34
  @doc "The span attribute keys a span may carry."
  @spec attribute_keys() :: [String.t(), ...]
  def attribute_keys, do: @attributes

  # OP-34
  # T-63 (2)
  @doc "Adds the current trace context and correlation id to the `:meta` option of a job being built."
  @spec job_opts(keyword()) :: keyword()
  def job_opts(opts), do: Jobs.opts(opts)

  # OP-34
  @doc "Attaches the handlers that carry trace context into every job; idempotent."
  @spec attach() :: :ok
  def attach, do: Jobs.attach()

  # OP-32
  @doc "The supervised children: the exporter, when an OTLP endpoint is configured."
  @spec children() :: [module()]
  def children, do: Exporter.children()

  defp restore(nil), do: Logger.metadata(traceparent: nil, trace_id: nil, span_id: nil)
  defp restore(parent), do: put(parent)

  defp allowed?({key, value}),
    do: key in @attributes and (is_binary(value) or is_integer(value) or is_boolean(value))

  defp format(trace, span), do: "00-" <> trace <> "-" <> span <> "-01"

  defp hex(n) do
    value = Base.encode16(Relay.Random.bytes(n), case: :lower)
    if value == String.duplicate("0", n * 2), do: hex(n), else: value
  end
end
