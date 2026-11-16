defmodule Relay.Webhooks.Envelope do
  @moduledoc """
  The event envelope of outbound delivery: CloudEvents 1.0 (WH-8).

  `encode/1` builds the structured-mode JSON body. It is deterministic: the context attributes come in a fixed order, extension attributes sorted by name, `data` last, and every object inside `data` has its keys sorted. The same event therefore gives the same bytes, and the same body digest, on every attempt. `attributes/1`, `binary_headers/2` and `data_body/1` give the binary mode of the queue and stream bindings, where the context attributes travel as message headers and the body is `data` alone.

  `id` is the `webhook-id` of the profile. The extensions are `seq` (monotonic per subject, WH-20), `traceparent` and `environment`. An envelope for a tenant's own events (`:relay_events`) may carry more extensions, such as the Access tenant; an envelope for a tenant's customers (`:destination`) never carries them, and its `source` is the value the tenant defined, so no internal tenant identifier leaves with it (WH-8 (4)).

  The payload is thin by default: the identifiers of the event and nothing else (WH-11). `snapshot/3` adds exactly the fields an endpoint allow-listed (WH-12), and `map_attributes/3` fills CloudEvents attributes from the fields of a tenant event (WH-13). No tenant code runs; these two are the only transformations.
  """

  alias Relay.Webhooks.Profile

  @enforce_keys [:id, :source, :type, :time]
  defstruct [
    :id,
    :source,
    :type,
    :time,
    :subject,
    :dataschema,
    :seq,
    :traceparent,
    :environment,
    datacontenttype: "application/json",
    data: %{},
    extensions: %{}
  ]

  @type usage :: :relay_events | :destination
  @type binding :: :http | :kafka | :amqp | :nats
  @type scalar :: String.t() | integer() | boolean()
  @type t :: %__MODULE__{
          id: String.t(),
          source: String.t(),
          type: String.t(),
          time: DateTime.t(),
          subject: String.t() | nil,
          dataschema: String.t() | nil,
          seq: non_neg_integer() | nil,
          traceparent: String.t() | nil,
          environment: Relay.Environment.t() | nil,
          datacontenttype: String.t(),
          data: map(),
          extensions: %{optional(String.t()) => scalar()}
        }
  @type error ::
          :invalid_id
          | :invalid_source
          | :invalid_type
          | :invalid_time
          | :invalid_attribute
          | :invalid_data
          | :invalid_extension
          | :extension_not_allowed

  @core ~w(specversion id source type time subject datacontenttype dataschema data)
  @typed ~w(seq traceparent environment)
  @reserved @core ++ @typed
  @relay_only ~w(accesstenant accessorganization correlationid)
  @extension_name ~r/\A[a-z0-9]{1,20}\z/
  @bindings %{http: "ce-", nats: "ce-", kafka: "ce_", amqp: "cloudEvents:"}

  # WH-8
  @doc """
  Builds an envelope from its fields: `:id`, `:source`, `:type` and `:time` (UTC) are required; `:subject`, `:dataschema`, `:datacontenttype`, `:data`, `:seq`, `:traceparent`, `:environment` and `:extensions` are optional. A `:destination` envelope refuses the extensions that only Relay's own events carry.
  """
  @spec new(usage(), map() | keyword()) :: {:ok, t()} | {:error, error()}
  def new(usage, fields) when usage in [:relay_events, :destination] do
    envelope = struct(__MODULE__, Map.new(fields))

    with :ok <- check(Profile.valid_id?(envelope.id), :invalid_id),
         :ok <- check(text?(envelope.source), :invalid_source),
         :ok <- check(text?(envelope.type), :invalid_type),
         :ok <- check(utc?(envelope.time), :invalid_time),
         :ok <- check(Enum.all?(texts(envelope), &optional_text?/1), :invalid_attribute),
         :ok <- check(text?(envelope.datacontenttype), :invalid_attribute),
         :ok <- check(envelope.environment in [nil, :live, :test], :invalid_attribute),
         :ok <- check(sequence?(envelope.seq), :invalid_attribute),
         :ok <- check(plain_map?(envelope.data), :invalid_data),
         :ok <- extensions(usage, envelope.extensions) do
      {:ok, envelope}
    end
  end

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp utc?(%DateTime{utc_offset: 0, std_offset: 0}), do: true
  defp utc?(_time), do: false

  defp texts(envelope), do: [envelope.subject, envelope.dataschema, envelope.traceparent]

  defp optional_text?(value), do: value == nil or text?(value)

  defp sequence?(seq), do: seq == nil or (is_integer(seq) and seq >= 0)

  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  # WH-8 (4)
  defp extensions(usage, extensions) when is_map(extensions) and not is_struct(extensions) do
    cond do
      not Enum.all?(extensions, &extension?/1) -> {:error, :invalid_extension}
      usage == :destination and relay_only?(extensions) -> {:error, :extension_not_allowed}
      true -> :ok
    end
  end

  defp extensions(_usage, _extensions), do: {:error, :invalid_extension}

  defp extension?({name, value}),
    do: extension_name?(name) and (is_binary(value) or is_integer(value) or is_boolean(value))

  defp extension_name?(name),
    do: is_binary(name) and Regex.match?(@extension_name, name) and name not in @reserved

  defp relay_only?(extensions), do: Enum.any?(@relay_only, &is_map_key(extensions, &1))

  # WH-8 (1)
  @doc "The media type of the structured-mode body."
  @spec content_type() :: String.t()
  def content_type, do: "application/cloudevents+json; charset=utf-8"

  # WH-8 (1)
  @doc "The structured-mode JSON body. The same envelope always gives the same bytes."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = envelope) do
    data = {"data", ordered(envelope.data)}
    Jason.encode!(Jason.OrderedObject.new(pairs(envelope) ++ [data]))
  end

  # WH-8 (3)
  @doc "The context attributes as text, in body order and without `data`: the attribute map of binary mode."
  @spec attributes(t()) :: [{String.t(), String.t()}]
  def attributes(%__MODULE__{} = envelope),
    do: Enum.map(pairs(envelope), fn {name, value} -> {name, text(value)} end)

  # WH-8 (3)
  @doc "The message headers of binary mode for a protocol binding: `ce-` for HTTP and NATS (values percent-encoded), `ce_` for Kafka, `cloudEvents:` for AMQP. `datacontenttype` is left out; it travels as the content type of the message."
  @spec binary_headers([{String.t(), String.t()}], binding()) :: [{String.t(), String.t()}]
  def binary_headers(attributes, binding) when is_map_key(@bindings, binding) do
    prefix = Map.fetch!(@bindings, binding)

    for {name, value} <- attributes, name != "datacontenttype" do
      {prefix <> name, header_value(binding, value)}
    end
  end

  defp header_value(binding, value) when binding in [:http, :nats],
    do: URI.encode(value, &(&1 in 0x21..0x7E and &1 not in [?", ?%]))

  defp header_value(_binding, value), do: value

  # WH-8 (3)
  @doc "The body of binary mode: `data` alone, with sorted keys."
  @spec data_body(t()) :: binary()
  def data_body(%__MODULE__{data: data}), do: data |> ordered() |> Jason.encode!()

  # WH-20 (3)
  @doc "The ordering key of the event, mapped to the partition key of a partitioned destination: its subject."
  @spec partition_key(t()) :: String.t() | nil
  def partition_key(%__MODULE__{subject: subject}), do: subject

  # WH-11
  # WH-13 (1)
  @doc "The thin payload: only the declared identifiers of the event."
  @spec thin(map(), [String.t()]) :: map()
  def thin(data, identifiers) when is_map(data) and is_list(identifiers),
    do: Map.take(data, identifiers)

  # WH-12
  # WH-13 (1)
  @doc "Adds the allow-listed fields of `source` to a thin payload. A field is a dotted path of object keys; a path that is absent adds nothing, and a field of the thin payload is never replaced."
  @spec snapshot(map(), map(), [String.t()]) :: map()
  def snapshot(thin, source, allow_list)
      when is_map(thin) and is_map(source) and is_list(allow_list),
      do: Enum.reduce(allow_list, thin, &allow(&2, source, &1))

  defp allow(payload, source, path) when is_binary(path) do
    segments = String.split(path, ".")

    case dig(source, segments) do
      {:ok, value} -> place(payload, segments, value)
      :error -> payload
    end
  end

  defp allow(payload, _source, _path), do: payload

  defp place(map, [key], value), do: Map.put_new(map, key, value)

  defp place(map, [key | rest], value) do
    case Map.get(map, key, %{}) do
      %{} = child -> Map.put(map, key, place(child, rest, value))
      _scalar -> map
    end
  end

  defp dig(value, []), do: {:ok, value}

  defp dig(%{} = map, [segment | rest]) do
    case Map.fetch(map, segment) do
      {:ok, value} -> dig(value, rest)
      :error -> :error
    end
  end

  defp dig(_value, _segments), do: :error

  # WH-13 (2)
  @doc "Fills CloudEvents attributes from the fields of a tenant event: `mapping` gives, for `subject` or for an extension attribute, the dotted path of the field that holds its value. A field that is absent or not a scalar sets nothing. Any other attribute cannot be mapped."
  @spec map_attributes(t(), map(), %{optional(String.t()) => String.t()}) ::
          {:ok, t()} | {:error, :attribute_not_mappable}
  def map_attributes(%__MODULE__{} = envelope, data, mapping)
      when is_map(data) and is_map(mapping) do
    mapping
    |> Enum.sort()
    |> Enum.reduce_while({:ok, envelope}, fn {attribute, path}, {:ok, acc} ->
      case mapped(acc, attribute, field(data, path)) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, {:error, :attribute_not_mappable}}
      end
    end)
  end

  defp field(data, path) when is_binary(path), do: dig(data, String.split(path, "."))
  defp field(_data, _path), do: :error

  defp mapped(envelope, "subject", {:ok, value}) when is_binary(value) and value != "",
    do: {:ok, %{envelope | subject: value}}

  defp mapped(envelope, "subject", _field), do: {:ok, envelope}

  defp mapped(envelope, name, field) do
    if extension_name?(name) and name not in @relay_only,
      do: {:ok, extend(envelope, name, field)},
      else: :error
  end

  defp extend(envelope, name, {:ok, value})
       when is_binary(value) or is_integer(value) or is_boolean(value),
       do: %{envelope | extensions: Map.put(envelope.extensions, name, value)}

  defp extend(envelope, _name, _field), do: envelope

  # WH-29
  @doc "The size of a payload in bytes, as measured against the hard limit."
  @spec size(binary()) :: non_neg_integer()
  def size(body) when is_binary(body), do: byte_size(body)

  # WH-29
  @doc "Checks a payload against the hard limit `max_bytes`."
  @spec check_size(binary(), non_neg_integer()) ::
          :ok | {:error, {:payload_too_large, non_neg_integer()}}
  def check_size(body, max_bytes) when is_binary(body) and is_integer(max_bytes) do
    size = byte_size(body)
    if size <= max_bytes, do: :ok, else: {:error, {:payload_too_large, size}}
  end

  defp pairs(envelope) do
    core = [
      {"specversion", "1.0"},
      {"id", envelope.id},
      {"source", envelope.source},
      {"type", envelope.type},
      {"time", DateTime.to_iso8601(envelope.time)},
      {"subject", envelope.subject},
      {"datacontenttype", envelope.datacontenttype},
      {"dataschema", envelope.dataschema}
    ]

    typed = %{
      "seq" => envelope.seq,
      "traceparent" => envelope.traceparent,
      "environment" => environment(envelope.environment)
    }

    extensions = envelope.extensions |> Map.merge(typed) |> Enum.sort()
    Enum.reject(core ++ extensions, fn {_name, value} -> value == nil end)
  end

  defp environment(nil), do: nil
  defp environment(environment), do: Relay.Environment.dump(environment)

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(true), do: "true"
  defp text(false), do: "false"

  defp ordered(%{} = map) when not is_struct(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
