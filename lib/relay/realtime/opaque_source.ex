defmodule Relay.Realtime.OpaqueSource do
  @moduledoc """
  The stream source of the opaque payload stream (IN-37, AG-44): AG-UI events of a subscriber. It asks the module set as `config :relay, Relay.Realtime.OpaqueSource, stream: module`, by default `Relay.Api.OpaqueStreams`, for the stream's signal topic, its head cursor, the events after a cursor and the badge counters, each taking the scope and the subscriber first. The realtime layer wraps what it gets in the one envelope and never reads a payload.
  """

  @behaviour Relay.Realtime.Source

  # IN-24
  @impl true
  def signal_topic(scope, subscriber_id), do: stream().signal_topic(scope, subscriber_id)

  # IN-22
  @impl true
  def head(scope, subscriber_id), do: stream().head(scope, subscriber_id)

  # IN-29
  # IN-37
  @impl true
  def changes(scope, subscriber_id, cursor, limit),
    do: stream().changes(scope, subscriber_id, cursor, limit)

  # IN-26
  @impl true
  def counters(scope, subscriber_id), do: stream().counters(scope, subscriber_id)

  defp stream do
    :relay
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:stream, Relay.Api.OpaqueStreams)
  end
end
