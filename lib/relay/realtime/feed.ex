defmodule Relay.Realtime.Feed do
  @moduledoc """
  One subscriber's stream as a connection reads it (IN-22, IN-24, IN-29). `open/5` subscribes the calling process to the stream's signal topic first and reads second, so nothing committed in between is lost (IN-28); without a cursor it starts at the stream's head. Every signal, and every re-read tick of the signal hub while Valkey is unavailable, leads to `catch_up/1`, which reads the changes after the cursor from the source and wraps them in envelopes with the current counters (IN-26). The signal carries nothing but a sequence number; the data always comes from the source (INV-53).

  When the source answers that the cursor is no longer valid, or more changes exist than one read carries (`truncated`), the connection gets `stream.resync_required` and continues from the head; the client then synchronises over REST (IN-29). The realtime layer never answers history queries itself (IN-32).
  """

  alias Relay.Realtime.Envelope

  @max Relay.Limits.fetch!(["realtime", "max_changes_per_read"])

  @enforce_keys [:scope, :subscriber_id, :source, :topic, :cursor]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          scope: Relay.Scope.t(),
          subscriber_id: Relay.Id.t(),
          source: module(),
          topic: String.t(),
          cursor: String.t()
        }

  # IN-22
  # IN-28
  @doc "Subscribes the calling process to the stream's signal and reads from `cursor`, or from the head when `nil`. With `counters: true` an open that finds nothing new still sends `inbox.counters_changed`."
  @spec open(Relay.Scope.t(), Relay.Id.t(), String.t() | nil, module(), keyword()) ::
          {:ok, t(), [Envelope.t()]} | {:error, term()}
  def open(scope, subscriber_id, cursor, source, opts \\ []) do
    with {:ok, topic} <- source.signal_topic(scope, subscriber_id),
         :ok <- Relay.Platform.subscribe_signal(topic) do
      feed = %__MODULE__{
        scope: scope,
        subscriber_id: subscriber_id,
        source: source,
        topic: topic,
        cursor: cursor
      }

      case first(feed) do
        {:ok, feed, envelopes} -> opened(feed, envelopes, Keyword.get(opts, :counters, true))
        {:error, _} = error -> close_on_error(feed, error)
      end
    end
  end

  # IN-24
  # IN-29
  @doc "Reads the changes after the feed's cursor and returns them as envelopes with the moved cursor."
  @spec catch_up(t()) :: {:ok, t(), [Envelope.t()]} | {:error, term()}
  def catch_up(%__MODULE__{} = feed) do
    case feed.source.changes(feed.scope, feed.subscriber_id, feed.cursor, @max) do
      {:ok, %{changes: [], cursor: cursor, truncated: false}} ->
        {:ok, %{feed | cursor: cursor}, []}

      {:ok, %{changes: changes, cursor: cursor, truncated: false}} ->
        with {:ok, counters} <- counters(feed),
             do: {:ok, %{feed | cursor: cursor}, envelopes(changes, cursor, counters)}

      {:ok, %{truncated: true}} ->
        resync(feed, "truncated")

      {:resync_required, reason} when is_binary(reason) ->
        resync(feed, reason)

      {:error, _} = error ->
        error
    end
  end

  @doc "True when a signal on `topic` is the feed's own."
  @spec signal?(t(), String.t()) :: boolean()
  def signal?(%__MODULE__{topic: topic}, topic), do: true
  def signal?(%__MODULE__{}, _topic), do: false

  @doc "Unsubscribes the calling process from the feed's signal."
  @spec close(t()) :: :ok
  def close(%__MODULE__{topic: topic}), do: Relay.Platform.unsubscribe_signal(topic)

  defp first(%__MODULE__{cursor: nil} = feed) do
    with {:ok, head} <- feed.source.head(feed.scope, feed.subscriber_id),
         do: {:ok, %{feed | cursor: head}, []}
  end

  defp first(feed), do: catch_up(feed)

  defp opened(feed, [], true) do
    case counters(feed) do
      {:ok, counters} ->
        data = Envelope.counters(counters)
        {:ok, feed, [build("inbox.counters_changed", data, counters, feed.cursor)]}

      {:error, _} = error ->
        close_on_error(feed, error)
    end
  end

  defp opened(feed, envelopes, _counters), do: {:ok, feed, envelopes}

  defp close_on_error(feed, error) do
    :ok = close(feed)
    error
  end

  defp resync(feed, reason) do
    with {:ok, head} <- feed.source.head(feed.scope, feed.subscriber_id),
         {:ok, counters} <- counters(feed) do
      envelope = build("stream.resync_required", %{"reason" => reason}, counters, head)
      {:ok, %{feed | cursor: head}, [envelope]}
    end
  end

  defp counters(feed), do: feed.source.counters(feed.scope, feed.subscriber_id)

  defp envelopes(changes, cursor, counters) do
    known = Enum.filter(changes, &(&1.t in Envelope.types()))
    last = length(known) - 1

    known
    |> Enum.with_index()
    |> Enum.map(fn {change, index} ->
      id = if index == last, do: cursor, else: Map.get(change, :cursor)
      build(change.t, change.d, counters, id)
    end)
  end

  defp build(type, data, counters, id),
    do: Envelope.build(type, data, counters, id, Relay.Clock.utc_now())
end
