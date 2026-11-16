defmodule Relay.Webhooks.Batch do
  @moduledoc """
  Batches of the object store destination (WH-21), pure: nothing here reads a clock, a limit or a store.

  A batch is written as one object of CloudEvents structured JSON lines: each event is its structured body on one line, in the order it joined the batch. `encode/1` gives those bytes and is deterministic, and `object_key/2` derives the object name from the batch identifier alone, so writing the same batch again writes the same object under the same name.

  A batch closes when it reaches the event count, the size or the age the caller passes, whichever comes first. `accepts?/3` tells whether an event still fits an open batch, `close_reason/3` whether and why a batch is to be closed now, and `closes_at/2` when its age alone will close it. The three limits are arguments.
  """

  alias Relay.Webhooks.Destination

  @enforce_keys [:id, :opened_at]
  defstruct [:id, :opened_at, bytes: 0, events: 0]

  @type t :: %__MODULE__{
          id: String.t(),
          opened_at: DateTime.t(),
          bytes: non_neg_integer(),
          events: non_neg_integer()
        }
  @type limits :: %{
          max_age_ms: pos_integer(),
          max_bytes: pos_integer(),
          max_events: pos_integer()
        }
  @type reason :: :events | :bytes | :age

  @content_type "application/x-ndjson"
  @extension ".jsonl"
  @event_type "relay.webhooks.batch"
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,199}\z/

  # WH-21
  @doc "The media type of a batch object."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  # WH-21
  @doc "An empty batch opened at `now`."
  @spec open(String.t(), DateTime.t()) :: t()
  def open(id, %DateTime{} = now) when is_binary(id) and id != "",
    do: %__MODULE__{id: id, opened_at: now}

  # WH-21
  @doc "The batch with one more event, the structured body `body`."
  @spec add(t(), binary()) :: t()
  def add(%__MODULE__{} = batch, body) when is_binary(body),
    do: %{batch | bytes: batch.bytes + line_bytes(body), events: batch.events + 1}

  # WH-21
  @doc "Whether an event still fits the batch. An empty batch takes any event, so an event larger than the size limit is written alone."
  @spec accepts?(t(), binary(), limits()) :: boolean()
  def accepts?(%__MODULE__{events: 0}, body, _limits) when is_binary(body), do: true

  def accepts?(%__MODULE__{} = batch, body, %{max_bytes: max_bytes, max_events: max_events})
      when is_binary(body),
      do: batch.events < max_events and batch.bytes + line_bytes(body) <= max_bytes

  # WH-21
  @doc "Why the batch is to be closed at `now`: it holds the allowed number of events, it holds the allowed bytes or it has been open for the allowed time. `nil` while it stays open; an empty batch is never closed."
  @spec close_reason(t(), DateTime.t(), limits()) :: reason() | nil
  def close_reason(%__MODULE__{events: 0}, %DateTime{}, _limits), do: nil

  def close_reason(%__MODULE__{} = batch, %DateTime{} = now, limits) do
    cond do
      batch.events >= limits.max_events -> :events
      batch.bytes >= limits.max_bytes -> :bytes
      DateTime.diff(now, batch.opened_at, :millisecond) >= limits.max_age_ms -> :age
      true -> nil
    end
  end

  # WH-21
  @doc "When the age of the batch closes it."
  @spec closes_at(t(), limits()) :: DateTime.t()
  def closes_at(%__MODULE__{opened_at: opened_at}, %{max_age_ms: max_age_ms}),
    do: DateTime.add(opened_at, max_age_ms, :millisecond)

  # WH-21
  @doc "The object name of a batch under `prefix`, derived from the batch identifier alone. An identifier that is not a plain file name is replaced by its SHA-256 digest."
  @spec object_key(String.t() | nil, String.t()) :: String.t()
  def object_key(prefix, id) when is_binary(id) and id != "" do
    name = if Regex.match?(@name, id), do: id, else: digest(id)
    directory(prefix) <> name <> @extension
  end

  defp digest(id), do: Base.encode16(:crypto.hash(:sha256, id), case: :lower)

  defp directory(prefix) when prefix in [nil, ""], do: ""

  defp directory(prefix) when is_binary(prefix),
    do: if(String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/")

  # WH-21
  @doc "The bytes of a batch object: every structured body on its own line. A body that holds a line break is not a line and is refused with its position."
  @spec encode([binary()]) :: {:ok, binary()} | {:error, {:not_a_line, non_neg_integer()}}
  def encode(bodies) when is_list(bodies) do
    case Enum.find_index(bodies, &(not line?(&1))) do
      nil -> {:ok, IO.iodata_to_binary(Enum.map(bodies, &[&1, ?\n]))}
      index -> {:error, {:not_a_line, index}}
    end
  end

  defp line?(body),
    do: is_binary(body) and body != "" and not String.contains?(body, ["\n", "\r"])

  # WH-21
  @doc "The message a destination is handed for a batch: the batch identifier as its identifier and the JSON lines of `bodies` as its body."
  @spec prepared(String.t(), [binary()], pos_integer()) ::
          {:ok, Destination.prepared()} | {:error, {:not_a_line, non_neg_integer()}}
  def prepared(id, bodies, attempt)
      when is_binary(id) and id != "" and is_integer(attempt) and attempt >= 1 do
    with {:ok, body} <- encode(bodies) do
      {:ok,
       %{
         id: id,
         type: @event_type,
         attempt: attempt,
         headers: [],
         body: body,
         content_type: @content_type,
         attributes: [],
         data: "",
         partition_key: nil
       }}
    end
  end

  defp line_bytes(body), do: byte_size(body) + 1
end
